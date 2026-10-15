defmodule Fugate.Scheduling.RunEvent do
  @moduledoc "An append-only history entry of a run."
  use Ash.Resource,
    otp_app: :fugate,
    domain: Fugate.Scheduling,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshJsonApi.Resource]

  sqlite do
    table "run_events"
    repo Fugate.Repo

    references do
      reference :run, on_delete: :delete
    end
  end

  json_api do
    type "run_event"
  end

  code_interface do
    define :record, action: :create, args: [:run_id, :kind, :data]
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:run_id, :kind, :data]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :kind, :string, allow_nil?: false, public?: true
    attribute :data, :map, allow_nil?: false, public?: true, default: %{}
    create_timestamp :inserted_at, public?: true
  end

  relationships do
    belongs_to :run, Fugate.Scheduling.Run,
      allow_nil?: false,
      public?: true,
      attribute_writable?: true
  end
end
