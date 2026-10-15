defmodule Fugate.Scheduling.Job.ValidateSchedule do
  @moduledoc "Checks the cron expression (`check: :cron`) or the time zone (`check: :timezone`)."
  use Ash.Resource.Validation

  alias Fugate.Scheduling.Job.Schedule

  @impl true
  def validate(changeset, [check: :timezone], _context) do
    if Schedule.valid_timezone?(Ash.Changeset.get_attribute(changeset, :timezone)),
      do: :ok,
      else: {:error, field: :timezone, message: "is not a known time zone"}
  end

  def validate(changeset, [check: :cron], _context) do
    with cron when is_binary(cron) <- Ash.Changeset.get_attribute(changeset, :cron),
         {:error, reason} <- Schedule.parse_cron(cron) do
      {:error, field: :cron, message: "is invalid: #{reason}"}
    else
      _valid_or_absent -> :ok
    end
  end
end
