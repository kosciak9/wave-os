defmodule Fugate.Scheduling.Job.Schedule do
  @moduledoc "Computes when a job is next due."

  alias Crontab.CronExpression.Parser

  @spec parse_cron(String.t()) :: {:ok, Crontab.CronExpression.t()} | {:error, String.t()}
  def parse_cron(cron) do
    case String.split(cron) do
      fields when length(fields) == 5 -> Parser.parse(cron)
      _ -> {:error, "must have exactly 5 fields"}
    end
  end

  @spec valid_timezone?(String.t()) :: boolean()
  def valid_timezone?(timezone), do: match?({:ok, _}, DateTime.now(timezone))

  @doc "Next moment after `now` at which `job` fires; nil when it never fires on its own."
  @spec next_run_at(map(), DateTime.t()) :: DateTime.t() | nil
  def next_run_at(%{enabled: false}, _now), do: nil
  def next_run_at(%{schedule: :manual}, _now), do: nil
  def next_run_at(%{schedule: :once, run_at: run_at}, _now), do: run_at

  def next_run_at(%{schedule: :cron, cron: cron, timezone: timezone}, now) do
    {:ok, expression} = parse_cron(cron)
    # The scheduler fires a due job at or after its minute, so the search starts
    # at the next whole minute to never return the occurrence being fired.
    from =
      now
      |> DateTime.shift_zone!(timezone)
      |> DateTime.truncate(:second)
      |> Map.put(:second, 0)
      |> DateTime.add(60, :second)

    # A wall-clock time repeated by a DST change fires once, at its first occurrence.
    expression = %{expression | on_ambiguity: [:prior]}
    {:ok, next} = Crontab.Scheduler.get_next_run_date(expression, from)
    next |> DateTime.shift_zone!("Etc/UTC") |> DateTime.truncate(:second) |> to_usec()
  end

  defp to_usec(datetime), do: %{datetime | microsecond: {0, 6}}
end
