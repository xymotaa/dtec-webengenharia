defmodule WCoreWeb.TelemetryComponents do
  @moduledoc """
  Componentes HEEx puros para o dashboard de telemetria da Planta 42.

  Nenhuma dependência de biblioteca JS de terceiros — apenas classes
  Tailwind/DaisyUI declaradas inline nos templates.
  """

  use Phoenix.Component

  @doc """
  Card de status de um nó (sensor/máquina).

  Exibe identificador, localização, badge de status, contador de eventos
  e o timestamp do último pulso recebido.

  ## Exemplo
      <.node_card
        id={@node.id}
        machine_identifier={@node.machine_identifier}
        location={@node.location}
        status={@node.status}
        event_count={@node.event_count}
        last_seen_at={@node.last_seen_at}
      />
  """
  attr :id, :integer, required: true
  attr :machine_identifier, :string, required: true
  attr :location, :string, required: true
  attr :status, :string, default: "unknown"
  attr :event_count, :integer, default: 0
  attr :last_seen_at, :any, default: nil

  def node_card(assigns) do
    ~H"""
    <div
      id={"node-#{@id}"}
      class={[
        "card shadow-md border-l-4 transition-all duration-300",
        card_border_class(@status)
      ]}
    >
      <div class="card-body p-4 gap-2">
        <div class="flex items-start justify-between">
          <div>
            <h3 class="card-title text-base font-mono">{@machine_identifier}</h3>
            <p class="text-xs text-base-content/60 flex items-center gap-1 mt-0.5">
              <svg xmlns="http://www.w3.org/2000/svg" class="size-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17.657 16.657L13.414 20.9a1.998 1.998 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z" />
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 11a3 3 0 11-6 0 3 3 0 016 0z" />
              </svg>
              {@location}
            </p>
          </div>
          <.status_badge status={@status} />
        </div>

        <div class="divider my-0" />

        <div class="flex justify-between text-xs text-base-content/70">
          <div class="flex items-center gap-1">
            <svg xmlns="http://www.w3.org/2000/svg" class="size-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z" />
            </svg>
            <span class="font-mono">{@event_count}</span>
            <span>eventos</span>
          </div>
          <div class="flex items-center gap-1">
            <svg xmlns="http://www.w3.org/2000/svg" class="size-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z" />
            </svg>
            <span>{format_timestamp(@last_seen_at)}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @doc """
  Badge colorido que representa o status operacional de um nó.

  Status suportados: "ok", "warning", "critical", "unknown".
  """
  attr :status, :string, required: true

  def status_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm font-semibold uppercase tracking-wide", badge_class(@status)]}>
      <span class={["size-1.5 rounded-full mr-1", dot_class(@status)]}></span>
      {@status}
    </span>
    """
  end

  @doc """
  Card de resumo para o painel de estatísticas do topo do dashboard.
  """
  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :color_class, :string, default: "text-base-content"

  def stat_card(assigns) do
    ~H"""
    <div class="stat bg-base-200 rounded-box">
      <div class="stat-title text-xs">{@label}</div>
      <div class={["stat-value text-2xl font-mono", @color_class]}>{@value}</div>
    </div>
    """
  end

  # ── Helpers privados ─────────────────────────────────────────────────────────

  defp card_border_class("ok"), do: "border-success"
  defp card_border_class("warning"), do: "border-warning"
  defp card_border_class("critical"), do: "border-error animate-pulse"
  defp card_border_class(_), do: "border-base-300"

  defp badge_class("ok"), do: "badge-success"
  defp badge_class("warning"), do: "badge-warning"
  defp badge_class("critical"), do: "badge-error"
  defp badge_class(_), do: "badge-ghost"

  defp dot_class("ok"), do: "bg-success-content"
  defp dot_class("warning"), do: "bg-warning-content"
  defp dot_class("critical"), do: "bg-error-content"
  defp dot_class(_), do: "bg-base-content/40"

  defp format_timestamp(nil), do: "aguardando..."

  defp format_timestamp(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%H:%M:%S")
  end

  defp format_timestamp(_), do: "—"
end
