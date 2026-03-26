defmodule WCore.Telemetry.Supervisor do
  @moduledoc """
  Supervisor da árvore OTP de telemetria em tempo real.

  Ordem dos filhos é intencional:
    1. Cache       → cria e detém a tabela ETS
    2. IngestServer → grava no ETS (depende do Cache estar vivo)
    3. WriteBehindWorker → lê do ETS e grava no SQLite (depende dos dois)

  Estratégia :rest_for_one:
    Se o Cache crashar, IngestServer e WriteBehindWorker são reiniciados
    junto com ele — pois dependem da tabela ETS que o Cache recria no init.
    Se apenas o IngestServer crashar, WriteBehindWorker não é afetado.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      WCore.Telemetry.Cache,
      WCore.Telemetry.IngestServer,
      WCore.Telemetry.WriteBehindWorker
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
