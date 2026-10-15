defmodule Fugate.Scheduling.Job.Advance do
  @moduledoc """
  After an occurrence fires: a one-time job is disabled, a cron job moves to its
  next future occurrence (missed occurrences are not caught up).
  """
  use Ash.Resource.Change

  alias Fugate.Scheduling.Job.Schedule

  @impl true
  def change(changeset, _opts, _context) do
    case changeset.data do
      %{schedule: :once} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:enabled, false)
        |> Ash.Changeset.force_change_attribute(:next_run_at, nil)

      job ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :next_run_at,
          Schedule.next_run_at(job, DateTime.utc_now())
        )
    end
  end
end
