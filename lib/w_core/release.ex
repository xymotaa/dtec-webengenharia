defmodule WCore.Release do
  @moduledoc """
  Tarefas de manutenção executadas dentro do release OTP (sem Mix disponível).

  Em produção não há Mix — este módulo expõe as operações necessárias
  para serem chamadas via `bin/w_core eval "WCore.Release.migrate()"`.

  Por que não usar Mix em produção?
  O release OTP é um artefato autossuficiente: apenas o código compilado
  e o runtime Erlang estão presentes. Mix é uma ferramenta de desenvolvimento
  e não faz parte do release. As migrações do Ecto precisam ser rodadas
  programaticamente via `Ecto.Migrator`.
  """

  @app :w_core

  @doc """
  Roda todas as migrações pendentes para todos os repositórios da aplicação.

  Chamado pelo script `rel/overlays/bin/migrate` antes de iniciar o servidor.
  """
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Reverte todas as migrações (útil para operações de manutenção emergencial).
  """
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  # ── Funções privadas ────────────────────────────────────────────────────────

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
