defmodule WCore.Telemetry.IngestServer do
  @moduledoc """
  GenServer responsável por receber eventos de sensores e gravar no ETS.

  Fluxo de um evento:
    1. Sensor chama `ingest/2` → cast assíncrono (não bloqueia o sensor)
    2. `handle_cast` grava no ETS via `Cache.upsert/4`
    3. Se o status mudou, publica no PubSub → LiveView reage instantaneamente

  Por que GenServer e não escrita direta no ETS?
  O GenServer serializa as escritas por nó, evitando condição de corrida
  entre o `insert_new` e o `update_element` do Cache. Para o Passo 4
  (10k eventos concorrentes), podemos evoluir para um pool de workers.
  """

  use GenServer

  alias WCore.Telemetry.Cache

  @pubsub WCore.PubSub
  @topic "telemetry:nodes"

  # ── API pública ──────────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ingere um evento de sensor de forma assíncrona.

  ## Parâmetros
    - `node_id`: ID inteiro do nó no banco de dados
    - `payload`: mapa com pelo menos `"status"` (ex: "ok", "warning", "critical")

  ## Exemplo
      WCore.Telemetry.IngestServer.ingest(42, %{"status" => "critical", "temp" => 98.5})
  """
  def ingest(node_id, payload) when is_integer(node_id) and is_map(payload) do
    GenServer.cast(__MODULE__, {:ingest, node_id, payload})
  end

  @doc """
  Drena a fila de mensagens do IngestServer (uso em testes).

  Como `call` entra na mesma mailbox que os `cast`s e é processado em ordem
  FIFO, este call só retorna após todos os casts anteriores serem processados.
  """
  def sync(timeout \\ 30_000) do
    GenServer.call(__MODULE__, :sync, timeout)
  end

  # ── Callbacks do GenServer ───────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:ingest, node_id, %{"status" => status} = payload}, state) do
    timestamp = DateTime.utc_now()
    encoded_payload = Jason.encode!(payload)

    # Captura estado anterior para detectar mudança de status
    previous = Cache.get(node_id)

    # Grava no ETS imediatamente — operação em memória, sub-microssegundo
    Cache.upsert(node_id, status, encoded_payload, timestamp)

    # Notifica o PubSub apenas quando o status muda para evitar flood
    if status_changed?(previous, status) do
      Phoenix.PubSub.broadcast(@pubsub, @topic, {:status_changed, node_id, status})
    end

    {:noreply, state}
  end

  # Ignora eventos com payload mal-formado (sem campo "status")
  def handle_cast({:ingest, _node_id, _payload}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:sync, _from, state) do
    {:reply, :ok, state}
  end

  # ── Funções privadas ─────────────────────────────────────────────────────────

  defp status_changed?(nil, _new_status), do: true
  defp status_changed?(%{status: old}, new) when old != new, do: true
  defp status_changed?(_, _), do: false
end
