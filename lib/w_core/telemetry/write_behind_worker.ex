defmodule WCore.Telemetry.WriteBehindWorker do
  @moduledoc """
  Worker que sincroniza periodicamente o estado quente do ETS para o SQLite.

  Padrão Write-Behind (write-back cache):
    - Eventos chegam → ETS atualizado imediatamente (rápido, em RAM)
    - A cada @sync_interval ms → este worker varre o ETS e faz upsert em lote no SQLite
    - Resultado: SQLite nunca sofre lock por evento individual

  Recuperação após crash/restart do servidor:
    - O SQLite contém o último estado sincronizado
    - O ETS é reconstruído gradualmente conforme novos eventos chegam
    - Histórico preservado; apenas eventos in-flight (<= @sync_interval ms) são perdidos
  """

  use GenServer

  require Logger

  alias WCore.Telemetry.Cache
  alias WCore.Telemetry, as: TelemetryContext

  # Intervalo de sincronização: 5 segundos
  @sync_interval 5_000

  # ── API pública ──────────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Força uma sincronização imediata (útil para testes)."
  def sync_now do
    GenServer.call(__MODULE__, :sync_now)
  end

  # ── Callbacks do GenServer ───────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    schedule_sync()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sync, state) do
    do_sync()
    schedule_sync()
    {:noreply, state}
  end

  @impl true
  def handle_call(:sync_now, _from, state) do
    do_sync()
    {:reply, :ok, state}
  end

  # ── Funções privadas ─────────────────────────────────────────────────────────

  defp schedule_sync do
    Process.send_after(self(), :sync, @sync_interval)
  end

  defp do_sync do
    entries = Cache.all()

    if entries != [] do
      Logger.debug("[WriteBehindWorker] Sincronizando #{length(entries)} nó(s) com o SQLite...")

      Enum.each(entries, fn %{node_id: node_id, status: status, event_count: count,
                               last_payload: payload, timestamp: ts} ->
        TelemetryContext.upsert_node_metric(%{
          node_id: node_id,
          status: status,
          total_events_processed: count,
          last_payload: payload,
          last_seen_at: ts
        })
      end)
    end
  end
end
