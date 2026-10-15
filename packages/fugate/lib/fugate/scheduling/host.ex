defmodule Fugate.Scheduling.Host do
  @moduledoc "A configured execution host with its live reachability and load."
  use Ash.Resource,
    otp_app: :fugate,
    domain: Fugate.Scheduling,
    extensions: [AshJsonApi.Resource]

  json_api do
    type "host"
  end

  actions do
    read :read do
      primary? true
      manual Fugate.Scheduling.Host.Read
    end
  end

  attributes do
    # The id repeats the name because JSON:API serializes a sole primary key only as the id.
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :reachable, :boolean, public?: true
    attribute :harnesses, {:array, :atom}, allow_nil?: false, public?: true
    attribute :max_concurrent, :integer, allow_nil?: false, public?: true
    attribute :active_runs, :integer, allow_nil?: false, public?: true
  end

  @doc "Exposes the global concurrency limit as top-level JSON:API meta."
  def json_api_metadata(_subject, _result, _request),
    do: %{max_concurrent: Fugate.Config.get().max_concurrent}
end
