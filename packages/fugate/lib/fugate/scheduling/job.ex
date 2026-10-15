defmodule Fugate.Scheduling.Job do
  @moduledoc "A prompt scheduled to run unattended in a repository."
  use Ash.Resource,
    otp_app: :fugate,
    domain: Fugate.Scheduling,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshJsonApi.Resource],
    simple_notifiers: [Fugate.Scheduling.SchedulerNotifier]

  alias Fugate.Scheduling.Job

  @editable [
    :name,
    :prompt,
    :repo_path,
    :harness,
    :schedule,
    :cron,
    :timezone,
    :run_at,
    :allowed_hosts,
    :enabled
  ]

  sqlite do
    table "jobs"
    repo Fugate.Repo
  end

  json_api do
    type "job"
  end

  code_interface do
    define :due
    define :next_due, not_found_error?: false
    define :advance
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept @editable
      change Job.ComputeNextRunAt
    end

    update :update do
      primary? true
      accept @editable
      require_atomic? false
      change Job.ComputeNextRunAt
    end

    destroy :destroy do
      primary? true
      require_atomic? false
      validate Job.NoActiveRun, before_action?: true
    end

    read :due do
      filter expr(enabled and not is_nil(next_run_at) and next_run_at <= now())
    end

    read :next_due do
      get? true
      filter expr(enabled and not is_nil(next_run_at))
      prepare build(sort: [next_run_at: :asc], limit: 1)
    end

    update :advance do
      description "Moves a job past the occurrence that has just fired."
      require_atomic? false
      change Job.Advance
    end
  end

  validations do
    validate present(:cron), where: [attribute_equals(:schedule, :cron)]
    validate absent(:cron), where: [negate(attribute_equals(:schedule, :cron))]
    validate present(:run_at), where: [attribute_equals(:schedule, :once)]
    validate absent(:run_at), where: [negate(attribute_equals(:schedule, :once))]
    validate match(:repo_path, ~r{\A/}), message: "must be an absolute path"
    validate {Job.ValidateSchedule, check: :cron}
    validate {Job.ValidateSchedule, check: :timezone}
    validate Job.ValidateAllowedHosts
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :prompt, :string, allow_nil?: false, public?: true
    attribute :repo_path, :string, allow_nil?: false, public?: true

    attribute :harness, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: Fugate.Config.harnesses()]

    attribute :schedule, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:cron, :once, :manual]]

    attribute :cron, :string, public?: true
    attribute :timezone, :string, allow_nil?: false, public?: true, default: "Europe/Warsaw"
    attribute :run_at, :utc_datetime_usec, public?: true

    attribute :allowed_hosts, {:array, :string},
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1]

    attribute :enabled, :boolean, allow_nil?: false, public?: true, default: true
    attribute :next_run_at, :utc_datetime_usec, public?: true, writable?: false

    timestamps(public?: true)
  end

  relationships do
    has_many :runs, Fugate.Scheduling.Run
  end

  identities do
    identity :unique_name, [:name]
  end
end
