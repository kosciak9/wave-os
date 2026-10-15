defmodule Fugate.Scheduling.Job.ValidateSchedule do
  @moduledoc "Checks the cron expression (`check: :cron`) or the time zone (`check: :timezone`)."
  use Ash.Resource.Validation

  alias Fugate.Scheduling.Job.Schedule

  @impl true
  def validate(changeset, [check: field], _context) do
    check(field, Ash.Changeset.get_attribute(changeset, field))
  end

  # A missing value is reported by the attribute's own presence rules.
  defp check(_field, nil), do: :ok

  defp check(:timezone, timezone) do
    if Schedule.valid_timezone?(timezone),
      do: :ok,
      else: {:error, field: :timezone, message: "is not a known time zone"}
  end

  defp check(:cron, cron) do
    case Schedule.parse_cron(cron) do
      {:ok, _expression} -> :ok
      {:error, reason} -> {:error, field: :cron, message: "is invalid: #{reason}"}
    end
  end
end
