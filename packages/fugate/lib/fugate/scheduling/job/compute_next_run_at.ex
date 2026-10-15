defmodule Fugate.Scheduling.Job.ComputeNextRunAt do
  @moduledoc """
  Recomputes `next_run_at` when the schedule or `enabled` changes, so an edit of
  unrelated fields never drops an occurrence that is due but not yet fired.
  """
  use Ash.Resource.Change

  alias Fugate.Scheduling.Job.Schedule

  @schedule_fields [:schedule, :cron, :timezone, :run_at, :enabled]

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      if changeset.action_type == :create or
           Enum.any?(@schedule_fields, &Ash.Changeset.changing_attribute?(changeset, &1)) do
        job = Map.new(@schedule_fields, &{&1, Ash.Changeset.get_attribute(changeset, &1)})

        Ash.Changeset.force_change_attribute(
          changeset,
          :next_run_at,
          Schedule.next_run_at(job, DateTime.utc_now())
        )
      else
        changeset
      end
    end)
  end
end
