defmodule WCore.Telemetry.NodeMetric do
  use Ecto.Schema
  import Ecto.Changeset

  schema "node_metrics" do
    field :status, :string
    field :total_events_processed, :integer
    field :last_payload, :string
    field :last_seen_at, :utc_datetime

    belongs_to :node, WCore.Telemetry.Node

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(node_metric, attrs) do
    node_metric
    |> cast(attrs, [:status, :total_events_processed, :last_payload, :last_seen_at, :node_id])
    |> validate_required([:status, :total_events_processed, :node_id])
    |> assoc_constraint(:node)
  end
end
