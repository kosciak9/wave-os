defmodule Fugate.Repo do
  use AshSqlite.Repo, otp_app: :fugate

  # SQLite allows a single writer; Ash wraps every write action in a transaction.
  def write_transactions?, do: true
end
