defmodule Fugate.Scheduling.Run do
  @moduledoc """
  One execution of a job by a coding agent driven through Herdr. A run stays the
  same run across continuations; it is active until it reaches a terminal state.
  """
  use Ash.Resource,
    otp_app: :fugate,
    domain: Fugate.Scheduling,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshJsonApi.Resource],
    simple_notifiers: [Fugate.Scheduling.SchedulerNotifier]

  alias Fugate.Scheduling.Run

  @active_states [:queued, :starting, :running, :waiting, :blocked, :unknown, :lost]
  @terminal_states [:completed, :failed, :abandoned]
  # Runs occupying a host slot: everything active except queued.
  @placed_states @active_states -- [:queued]

  def active_states, do: @active_states
  def placed_states, do: @placed_states

  sqlite do
    table "runs"
    repo Fugate.Repo

    references do
      reference :job, on_delete: :delete
    end

    custom_indexes do
      index [:job_id],
        name: "runs_one_active_per_job",
        unique: true,
        where: "state IN (#{Enum.map_join(@active_states, ", ", &"'#{&1}'")})",
        message: "job already has an active run"
    end
  end

  json_api do
    type "run"
    includes [:events]
  end

  code_interface do
    define :trigger, args: [:job_id]
    define :schedule, args: [:job_id]
    define :transition, args: [:event]
    define :abandon
    define :archive
    define :with_session
    define :active_for_job, args: [:job_id], get?: true, not_found_error?: false
    define :placed_on_pane, args: [:pane_id], get?: true, not_found_error?: false
    define :active
    define :placed
    define :queued
    define :wake_due
    define :next_wake, get?: true, not_found_error?: false
  end

  actions do
    defaults [:read]

    read :list do
      description "Runs, newest first unless sorted otherwise."
      pagination offset?: true, required?: false, countable: true
      prepare build(default_sort: [inserted_at: :desc])
    end

    create :trigger do
      description "Manually triggers a job; refused while the job has an active run."
      accept [:job_id]
      validate Run.ValidateJobExists
      change set_attribute(:trigger, :manual)
      change {Run.RecordEvent, kind: "queued"}
    end

    create :schedule do
      accept [:job_id]
      change set_attribute(:trigger, :schedule)
      change {Run.RecordEvent, kind: "queued"}
    end

    update :transition do
      description "Persists one lifecycle step together with its run event."
      require_atomic? false

      accept [
        :state,
        :host,
        :workspace_id,
        :pane_id,
        :agent_name,
        :terminal_id,
        :agent_session,
        :last_turn,
        :turn_epoch,
        :status_check_sent,
        :wake_at,
        :checkpoint_at,
        :finished_at
      ]

      argument :event, :string, allow_nil?: false
      argument :event_data, :map, default: %{}
      # A terminal run is final, even when the scheduler holds an older copy of it.
      change filter(expr(state in ^@active_states))
      change Run.RecordEvent
    end

    update :abandon do
      description "Marks an active run abandoned without touching its agent."
      require_atomic? false
      validate attribute_in(:state, @active_states), message: "run is not active"
      change filter(expr(state in ^@active_states))
      change set_attribute(:state, :abandoned)
      change set_attribute(:finished_at, &DateTime.utc_now/0)
      change {Run.RecordEvent, kind: "abandoned"}
    end

    update :archive do
      description "Closes a finished run's Herdr session: its agent, and its workspace with it."
      require_atomic? false
      validate attribute_in(:state, @terminal_states), message: "run is not finished"
      validate present(:pane_id), message: "run has no Herdr session"
      validate absent(:archived_at), message: "run is already archived"
      change Run.ArchiveAgent
      change set_attribute(:archived_at, &DateTime.utc_now/0)
      change {Run.RecordEvent, kind: "archived"}
    end

    read :with_session do
      description "Runs whose Herdr session has not been archived."
      filter expr(not is_nil(pane_id) and is_nil(archived_at))
      prepare build(sort: [inserted_at: :asc])
    end

    read :active_for_job do
      argument :job_id, :uuid, allow_nil?: false
      filter expr(job_id == ^arg(:job_id) and state in ^@active_states)
    end

    read :placed_on_pane do
      description "The run driving the agent in a pane; a lost run's pane id may have been reused."
      argument :pane_id, :string, allow_nil?: false
      filter expr(pane_id == ^arg(:pane_id) and state in ^(@placed_states -- [:lost]))
      prepare build(sort: [inserted_at: :desc], limit: 1)
    end

    read :active do
      description "Active runs, newest first."
      filter expr(state in ^@active_states)
      prepare build(default_sort: [inserted_at: :desc])
    end

    read :finished do
      description "Finished runs, most recently finished first."
      filter expr(state in ^@terminal_states)
      pagination offset?: true, required?: true, default_limit: 20, countable: true
      prepare build(default_sort: [finished_at: :desc])
    end

    read :placed do
      filter expr(state in ^@placed_states and not is_nil(host))
    end

    read :queued do
      filter expr(state == :queued)
      prepare build(sort: [inserted_at: :asc], load: [:job])
    end

    read :wake_due do
      filter expr(state == :waiting and wake_at <= now())
    end

    read :next_wake do
      get? true
      filter expr(state == :waiting and not is_nil(wake_at))
      prepare build(sort: [wake_at: :asc], limit: 1)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :trigger, :atom,
      allow_nil?: false,
      public?: true,
      default: :manual,
      constraints: [one_of: [:schedule, :manual]]

    attribute :state, :atom,
      allow_nil?: false,
      public?: true,
      default: :queued,
      constraints: [one_of: @active_states ++ @terminal_states]

    attribute :host, :string, public?: true
    attribute :workspace_id, :string, public?: true
    attribute :pane_id, :string, public?: true
    attribute :agent_name, :string, public?: true
    attribute :terminal_id, :string, public?: true
    attribute :agent_session, :string, public?: true
    attribute :last_turn, :integer, public?: true

    attribute :turn_epoch, :integer,
      public?: true,
      description: "Herdr turn counter epoch of `last_turn`; a new epoch restarts the counter."

    attribute :status_check_sent, :boolean,
      allow_nil?: false,
      public?: true,
      default: false,
      description:
        "A status question was sent since the last recognised status; no further one is sent."

    attribute :wake_at, :utc_datetime_usec, public?: true
    attribute :checkpoint_at, :utc_datetime_usec, public?: true
    attribute :finished_at, :utc_datetime_usec, public?: true
    attribute :archived_at, :utc_datetime_usec, public?: true

    timestamps(public?: true)
  end

  relationships do
    belongs_to :job, Fugate.Scheduling.Job,
      allow_nil?: false,
      public?: true,
      attribute_writable?: true

    has_many :events, Fugate.Scheduling.RunEvent, public?: true, sort: [inserted_at: :asc]
  end
end
