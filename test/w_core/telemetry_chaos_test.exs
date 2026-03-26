defmodule WCore.TelemetryChaosTest do
  @moduledoc """
  Simulação de Caos — Passo 4 do desafio W-Core.

  Injeta 10.000 eventos verdadeiramente concorrentes em um único nó e prova:
    1. O ETS não perdeu nenhum evento (event_count == 10_000)
    2. Não houve condição de corrida (sem panic, sem inconsistência)
    3. O SQLite sincronizou corretamente via Write-Behind
  """

  # async: false → sandbox em modo shared → WriteBehindWorker pode usar o Repo
  use WCore.DataCase, async: false

  alias WCore.Telemetry
  alias WCore.Telemetry.{Cache, IngestServer, WriteBehindWorker}

  @event_count 10_000

  describe "simulação de caos — #{@event_count} eventos concorrentes" do
    test "ETS não perde eventos e o SQLite sincroniza corretamente" do
      # Com sandbox em modo shared (async: false), qualquer processo pode usar
      # o Repo do teste. Chamamos allow explicitamente para garantir.
      Ecto.Adapters.SQL.Sandbox.allow(
        WCore.Repo,
        self(),
        Process.whereis(WriteBehindWorker)
      )

      # Cria nó com identificador único para não colidir com outros testes
      {:ok, node} =
        Telemetry.create_node(%{
          machine_identifier: "CHAOS-#{System.unique_integer([:positive])}",
          location: "Zona de Caos"
        })

      # ── Fase 1: Ingestão concorrente ─────────────────────────────────────────
      # Task.async_stream dispara max_concurrency tarefas em paralelo real.
      # Cada task chama GenServer.cast (fire-and-forget) — não bloqueia.
      1..@event_count
      |> Task.async_stream(
        fn i ->
          # Varia o status a cada 500 eventos para exercitar as transições
          status = if rem(i, 500) == 0, do: "warning", else: "ok"
          IngestServer.ingest(node.id, %{"status" => status, "seq" => i})
        end,
        max_concurrency: System.schedulers_online() * 4,
        timeout: 60_000
      )
      |> Stream.run()

      # ── Fase 2: Drena a fila do IngestServer ─────────────────────────────────
      # Este call entra na mailbox DEPOIS dos 10k casts e só retorna quando
      # todos foram processados. É a forma correta de sincronizar com GenServer.
      IngestServer.sync(60_000)

      # ── Assertiva 1: ETS não perdeu nenhum evento ─────────────────────────────
      entry = Cache.get(node.id)

      assert entry != nil,
             "Nó #{node.id} ausente no ETS após #{@event_count} eventos"

      assert entry.event_count == @event_count,
             "ETS perdeu eventos — esperado: #{@event_count}, obtido: #{entry.event_count}"

      # ── Assertiva 2: Sem condição de corrida ──────────────────────────────────
      # Se houvesse race condition entre insert_new e update_element,
      # o event_count seria menor que @event_count. A assertiva acima já prova
      # isso. Adicionalmente, verificamos que o status é um valor válido.
      assert entry.status in ~w(ok warning),
             "Status inválido no ETS: #{entry.status}"

      # ── Fase 3: Sincronização Write-Behind → SQLite ───────────────────────────
      # Força a sincronização imediata sem esperar o timer de 5s
      WriteBehindWorker.sync_now()

      metric = Telemetry.get_node_metric(node.id)

      assert metric != nil,
             "node_metric não encontrado no SQLite para node_id=#{node.id}"

      # ── Assertiva 3: SQLite sincronizou com o ETS ─────────────────────────────
      assert metric.total_events_processed == @event_count,
             "SQLite dessincronizado — esperado: #{@event_count}, obtido: #{metric.total_events_processed}"

      # ── Assertiva 4: Consistência entre ETS e SQLite ──────────────────────────
      # O status no SQLite deve refletir o último estado do ETS
      assert metric.status == entry.status,
             "Status inconsistente — ETS: #{entry.status}, SQLite: #{metric.status}"
    end
  end
end
