defmodule Fugate.Scheduling.Job.NoActiveRun do
  @moduledoc "Refuses to delete a job whose run is still active."
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    if Fugate.Scheduling.Run.active_for_job!(changeset.data.id) do
      {:error, field: :id, message: "job has an active run; abandon it first"}
    else
      :ok
    end
  end
end
