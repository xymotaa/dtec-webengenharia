defmodule WCore.Telemetry.Cache do
  @moduledoc """
  Processo dono da tabela ETS `:w_core_telemetry_cache`.

  Responsabilidade única: criar e manter a tabela ETS viva.
  Toda a lógica de leitura e escrita é exposta via funções públicas
  que qualquer processo pode chamar diretamente — ETS é :public.

  Estrutura da tupla: {node_id, status, event_count, last_payload, timestamp}
  """

  use GenServer

  @table :w_core_telemetry_cache

  # ── API pública ──────────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Insere ou atualiza o estado de um nó no ETS.

  Usa `insert_new/2` para detectar a primeira chegada e, nas
  subsequentes, `update_counter/3` para incrementar o contador de
  eventos atomicamente — sem precisar de lock ou passagem pelo GenServer.
  """
  def upsert(node_id, status, last_payload, timestamp) do
    case :ets.insert_new(@table, {node_id, status, 1, last_payload, timestamp}) do
      true ->
        :ok

      false ->
        # Incremento atômico do contador (posição 3 na tupla)
        :ets.update_counter(@table, node_id, {3, 1})
        # Atualiza os demais campos sem tocar no contador
        :ets.update_element(@table, node_id, [
          {2, status},
          {4, last_payload},
          {5, timestamp}
        ])
    end
  end

  @doc "Retorna o estado atual de um nó, ou nil se não existir."
  def get(node_id) do
    case :ets.lookup(@table, node_id) do
      [{^node_id, status, count, payload, ts}] ->
        %{node_id: node_id, status: status, event_count: count, last_payload: payload, last_seen_at: ts}

      [] ->
        nil
    end
  end

  @doc "Retorna todos os nós presentes no cache."
  def all do
    :ets.tab2list(@table)
    |> Enum.map(fn {node_id, status, count, payload, ts} ->
      %{node_id: node_id, status: status, event_count: count, last_payload: payload, last_seen_at: ts}
    end)
  end

  # ── Callbacks do GenServer ───────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # :set        → uma entrada por chave (node_id), sobrescreve duplicatas
    # :public     → qualquer processo pode ler e escrever (LiveView lê direto)
    # :named_table → acessível pelo nome :w_core_telemetry_cache
    # read_concurrency: true → otimizado para muitos leitores simultâneos
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end
end
