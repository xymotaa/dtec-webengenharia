defmodule WCore.Telemetry do
  @moduledoc """
  Contexto público do domínio Telemetry.

  Regra: nenhum módulo fora deste contexto acessa WCore.Repo diretamente
  para dados de telemetria. Toda interação com o banco passa por aqui.

  Separação de preocupações (base CQRS):
    - Escrita: eventos chegam pelo IngestServer → ETS → upsert_node_metric/1
    - Leitura: LiveView lê do ETS via Cache (dados quentes) ou do banco (histórico)
  """

  import Ecto.Query

  alias WCore.Repo
  alias WCore.Telemetry.{Node, NodeMetric}

  # ── Nodes ────────────────────────────────────────────────────────────────────

  def list_nodes do
    Repo.all(Node)
  end

  def get_node!(id), do: Repo.get!(Node, id)

  def get_node_by_identifier(machine_identifier) do
    Repo.get_by(Node, machine_identifier: machine_identifier)
  end

  def create_node(attrs) do
    %Node{}
    |> Node.changeset(attrs)
    |> Repo.insert()
  end

  # ── NodeMetrics ──────────────────────────────────────────────────────────────

  @doc """
  Upsert do estado consolidado de um nó no SQLite.

  Chamado pelo WriteBehindWorker a cada ciclo de sincronização.
  Usa `on_conflict` para atualizar apenas os campos voláteis
  sem tocar no `inserted_at`.
  """
  def upsert_node_metric(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs_with_timestamp = Map.put_new(attrs, :last_seen_at, now)

    %NodeMetric{}
    |> NodeMetric.changeset(attrs_with_timestamp)
    |> Repo.insert(
      on_conflict: {:replace, [:status, :total_events_processed, :last_payload, :last_seen_at, :updated_at]},
      conflict_target: :node_id
    )
  end

  @doc "Retorna o NodeMetric de um nó, ou nil."
  def get_node_metric(node_id) do
    Repo.get_by(NodeMetric, node_id: node_id)
  end

  @doc "Lista todos os nós com seus últimos metrics."
  def list_nodes_with_metrics do
    Node
    |> preload(:node_metric)
    |> Repo.all()
  end
end
