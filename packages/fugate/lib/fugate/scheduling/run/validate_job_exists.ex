defmodule Fugate.Scheduling.Run.ValidateJobExists do
  @moduledoc "Reports a missing job on `job_id` instead of as a foreign key failure."
  use Ash.Resource.Validation

  require Ash.Query

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :job_id) do
      nil ->
        :ok

      job_id ->
        if Fugate.Scheduling.Job |> Ash.Query.filter(id == ^job_id) |> Ash.exists?(),
          do: :ok,
          else: {:error, field: :job_id, message: "job does not exist"}
    end
  end
end
