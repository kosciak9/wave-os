defmodule Fugate.Scheduling.Job.Advance do
  @moduledoc """
  After an occurrence fires: a one-time job is disabled, a cron job moves to its
  next future occurrence (missed occurrences are not caught up).

  The job is re-read inside the write transaction, so an edit saved since the
  occurrence fired wins: when it already moved `next_run_at`, nothing changes.
  """
  use Ash.Resource.Change

  alias Fugate.Scheduling.Job
  alias Fugate.Scheduling.Job.Schedule

  @impl true
  def change(changeset, _opts, _context) do
    fired_at = changeset.data.next_run_at

    Ash.Changeset.before_action(changeset, fn changeset ->
      advance(changeset, Ash.get!(Job, changeset.data.id), fired_at)
    end)
  end

  defp advance(changeset, %Job{next_run_at: fired_at, schedule: :once}, fired_at) do
    changeset
    |> Ash.Changeset.force_change_attribute(:enabled, false)
    |> Ash.Changeset.force_change_attribute(:next_run_at, nil)
  end

  defp advance(changeset, %Job{next_run_at: fired_at} = job, fired_at) do
    Ash.Changeset.force_change_attribute(
      changeset,
      :next_run_at,
      Schedule.next_run_at(job, DateTime.utc_now())
    )
  end

  defp advance(changeset, _edited_meanwhile, _fired_at), do: changeset
end
