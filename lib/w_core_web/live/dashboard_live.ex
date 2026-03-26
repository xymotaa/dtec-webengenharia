defmodule WCoreWeb.DashboardLive do
  @moduledoc """
  Dashboard em tempo real da Sala de Controle — Planta 42.

  Fluxo de dados:
    1. mount/3 → carrega nós do banco + estado quente do ETS
    2. PubSub `{:status_changed, node_id, status}` → atualiza O(1) via Map
    3. :tick a cada 3s → sincroniza contadores de eventos do ETS

  Por que separar PubSub e :tick?
    O PubSub garante que a tela "pisque" IMEDIATAMENTE na falha (requisito
    crítico do briefing). O :tick mantém os contadores de eventos atualizados
    sem sobrecarregar o PubSub com broadcasts por evento individual.
  """

  use WCoreWeb, :live_view

  import WCoreWeb.TelemetryComponents

  alias WCore.Telemetry
  alias WCore.Telemetry.Cache

  @pubsub WCore.PubSub
  @topic "telemetry:nodes"
  @tick_interval 3_000

  # ── Mount ────────────────────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(@pubsub, @topic)
      Process.send_after(self(), :tick, @tick_interval)
    end

    nodes = build_nodes_map()

    {:ok,
     socket
     |> assign(:page_title, "Sala de Controle — W-Core")
     |> assign(:nodes, nodes)}
  end

  # ── Handlers de eventos ──────────────────────────────────────────────────────

  @impl true
  def handle_info({:status_changed, node_id, _status}, socket) do
    # Atualização cirúrgica: busca o estado completo do nó no ETS (O(1))
    # e re-renderiza apenas o card afetado via diff do LiveView
    nodes =
      case Cache.get(node_id) do
        nil ->
          socket.assigns.nodes

        entry ->
          Map.update(socket.assigns.nodes, node_id, entry, fn existing ->
            Map.merge(existing, Map.take(entry, [:status, :event_count, :last_seen_at]))
          end)
      end

    {:noreply, assign(socket, :nodes, nodes)}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_interval)

    # Atualiza contadores de eventos de todos os nós a partir do ETS
    # Sem hit no banco — leitura pura de memória
    nodes =
      Enum.reduce(Cache.all(), socket.assigns.nodes, fn entry, acc ->
        Map.update(acc, entry.node_id, entry, fn existing ->
          Map.merge(existing, Map.take(entry, [:status, :event_count, :last_seen_at]))
        end)
      end)

    {:noreply, assign(socket, :nodes, nodes)}
  end

  # ── Render ───────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :stats, compute_stats(assigns.nodes))

    ~H"""
    <div class="min-h-screen bg-base-100">
      <%!-- Cabeçalho da Sala de Controle --%>
      <div class="bg-base-200 border-b border-base-300 px-4 sm:px-8 py-4">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-xl font-bold tracking-tight">Sala de Controle</h1>
            <p class="text-xs text-base-content/60 mt-0.5">Planta 42 — Motor de Estado W-Core</p>
          </div>
          <div class="flex items-center gap-2">
            <span class="size-2 rounded-full bg-success animate-pulse"></span>
            <span class="text-xs text-base-content/60">ao vivo</span>
          </div>
        </div>
      </div>

      <div class="px-4 sm:px-8 py-6 space-y-6">
        <%!-- Painel de estatísticas --%>
        <div class="stats stats-horizontal w-full shadow">
          <.stat_card label="Total de Nós" value={@stats.total} />
          <.stat_card label="Operacionais" value={@stats.ok} color_class="text-success" />
          <.stat_card label="Atenção" value={@stats.warning} color_class="text-warning" />
          <.stat_card label="Críticos" value={@stats.critical} color_class="text-error" />
        </div>

        <%!-- Grade de cards dos nós --%>
        <div>
          <h2 class="text-sm font-semibold text-base-content/60 uppercase tracking-widest mb-3">
            Sensores Monitorados
          </h2>

          <%= if map_size(@nodes) == 0 do %>
            <div class="flex flex-col items-center justify-center py-20 text-base-content/40">
              <svg xmlns="http://www.w3.org/2000/svg" class="size-12 mb-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M9 3H5a2 2 0 00-2 2v4m6-6h10a2 2 0 012 2v4M9 3v18m0 0h10a2 2 0 002-2V9M9 21H5a2 2 0 01-2-2V9m0 0h18" />
              </svg>
              <p class="text-sm">Nenhum sensor cadastrado.</p>
              <p class="text-xs mt-1">Registre nós via API para começar o monitoramento.</p>
            </div>
          <% else %>
            <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4">
              <%= for {_id, node} <- @nodes do %>
                <.node_card
                  id={node.id}
                  machine_identifier={node.machine_identifier}
                  location={node.location}
                  status={node.status}
                  event_count={node.event_count}
                  last_seen_at={node.last_seen_at}
                />
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ── Funções privadas ─────────────────────────────────────────────────────────

  defp build_nodes_map do
    cache_index =
      Cache.all()
      |> Enum.into(%{}, fn entry -> {entry.node_id, entry} end)

    Telemetry.list_nodes()
    |> Enum.into(%{}, fn node ->
      cache = Map.get(cache_index, node.id, %{status: "unknown", event_count: 0, last_seen_at: nil})

      entry = %{
        id: node.id,
        machine_identifier: node.machine_identifier,
        location: node.location,
        status: cache.status,
        event_count: cache.event_count,
        last_seen_at: cache.last_seen_at
      }

      {node.id, entry}
    end)
  end

  defp compute_stats(nodes) do
    Enum.reduce(nodes, %{total: 0, ok: 0, warning: 0, critical: 0}, fn {_, node}, acc ->
      acc = Map.update!(acc, :total, &(&1 + 1))

      case node.status do
        s when s in ~w(ok warning critical) ->
          Map.update!(acc, String.to_existing_atom(s), &(&1 + 1))

        _ ->
          acc
      end
    end)
  end
end
