defmodule Fugate.Scheduling.Repository do
  @moduledoc "A git checkout under `~/Developer` on Fugate's own host, offered as a job's repository."
  use Ash.Resource,
    otp_app: :fugate,
    domain: Fugate.Scheduling,
    extensions: [AshJsonApi.Resource]

  json_api do
    type "repository"
  end

  actions do
    read :read do
      primary? true
      manual Fugate.Scheduling.Repository.Read
    end
  end

  attributes do
    # The path relative to `~/Developer`, such as `personal/wave-os`.
    attribute :id, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :path, :string, allow_nil?: false, public?: true
  end
end
