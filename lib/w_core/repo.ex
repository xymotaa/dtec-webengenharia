defmodule WCore.Repo do
  use Ecto.Repo,
    otp_app: :w_core,
    adapter: Ecto.Adapters.SQLite3
end
