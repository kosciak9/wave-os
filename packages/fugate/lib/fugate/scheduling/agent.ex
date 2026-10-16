defmodule Fugate.Scheduling.Agent do
  @moduledoc """
  An agent in Herdr's directory, on this host or a federated machine, whether
  Fugate started it or not.
  """
  use Ash.Resource,
    otp_app: :fugate,
    domain: Fugate.Scheduling,
    extensions: [AshJsonApi.Resource]

  json_api do
    type "agent"
  end

  actions do
    read :read do
      primary? true
      manual Fugate.Scheduling.Agent.Read
    end
  end

  attributes do
    # Pane ids are only unique per machine, so the id is `machine/pane_id`.
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :machine, :string, public?: true
    attribute :kind, :string, public?: true, description: "The harness, such as claude or codex."
    attribute :title, :string, public?: true

    attribute :status, :string,
      public?: true,
      description: "Herdr's agent status: idle, working, blocked, done or unknown."

    attribute :status_since, :utc_datetime_usec, public?: true
    attribute :cwd, :string, public?: true
    attribute :run_id, :string, public?: true, description: "The Fugate run driving the agent."
  end
end
