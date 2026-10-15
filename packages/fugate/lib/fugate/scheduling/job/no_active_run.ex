defmodule Fugate.Scheduling.Job.NoActiveRun do
  @moduledoc "Refuses to delete a job whose run is still active."
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Fugate.Scheduling.Run.active_for_job!(changeset.data.id) do
      nil -> :ok
      _active -> {:error, field: :id, message: "job has an active run; abandon it first"}
    end
  end
end
