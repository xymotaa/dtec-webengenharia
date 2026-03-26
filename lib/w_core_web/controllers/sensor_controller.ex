defmodule WCoreWeb.SensorController do
  @moduledoc """
  API JSON para receber pulsos (heartbeats) dos sensores da Planta 42.

  Endpoint: POST /api/nodes/:machine_identifier/pulse
  Body (JSON): {"status": "ok|warning|critical", ...métricas arbitrárias...}

  O controller apenas valida que o nó existe e delega ao IngestServer.
  O IngestServer grava no ETS e notifica o PubSub — operação assíncrona,
  então este endpoint retorna imediatamente sem esperar a gravação.
  """

  use WCoreWeb, :controller

  alias WCore.Telemetry
  alias WCore.Telemetry.IngestServer

  @valid_statuses ~w(ok warning critical)

  def pulse(conn, %{"machine_identifier" => machine_id} = params) do
    payload = Map.drop(params, ["machine_identifier"])

    with {:node, node} when not is_nil(node) <-
           {:node, Telemetry.get_node_by_identifier(machine_id)},
         {:status, true} <-
           {:status, Map.get(payload, "status") in @valid_statuses} do
      IngestServer.ingest(node.id, payload)
      json(conn, %{ok: true, node_id: node.id})
    else
      {:node, nil} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "node '#{machine_id}' not found"})

      {:status, false} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "status must be one of: #{Enum.join(@valid_statuses, ", ")}"})
    end
  end
end
