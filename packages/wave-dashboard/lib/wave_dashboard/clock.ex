defmodule WaveDashboard.Clock do
  @moduledoc """
  Wall-clock time for rendering. Local time comes from the OS, which already
  knows the host's zone, so no time zone database is needed.
  """

  @doc "Sends `message` to the caller at the start of the next minute."
  def tick_next_minute(message) do
    %Time{second: second, microsecond: {microsecond, _precision}} = Time.utc_now()
    Process.send_after(self(), message, :timer.seconds(60 - second) - div(microsecond, 1000))
  end

  def to_local(%DateTime{} = at) do
    at
    |> DateTime.to_naive()
    |> NaiveDateTime.to_erl()
    |> :calendar.universal_time_to_local_time()
    |> NaiveDateTime.from_erl!()
  end

  @doc "A duration in whole minutes as `3d 4h`, `4h 05m` or `12m`."
  def duration(minutes) when minutes >= 24 * 60,
    do: "#{div(minutes, 24 * 60)}d #{div(rem(minutes, 24 * 60), 60)}h"

  def duration(minutes) when minutes >= 60,
    do: "#{div(minutes, 60)}h #{pad(rem(minutes, 60))}m"

  def duration(minutes), do: "#{minutes}m"

  @doc "`at` relative to `now`, such as `in 2h 05m` or `12m ago`."
  def relative(nil, _now), do: "—"

  def relative(%DateTime{} = at, %DateTime{} = now) do
    case DateTime.diff(at, now, :minute) do
      0 -> "now"
      minutes when minutes > 0 -> "in " <> duration(minutes)
      minutes -> duration(-minutes) <> " ago"
    end
  end

  def format(nil), do: "—"
  def format(%DateTime{} = at), do: at |> to_local() |> Calendar.strftime("%Y-%m-%d %H:%M")

  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")
end
