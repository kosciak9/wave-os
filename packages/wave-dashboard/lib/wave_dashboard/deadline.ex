defmodule WaveDashboard.Deadline do
  @moduledoc """
  The single shared deadline. Dates are calendar days in the host's local time
  zone, so day counts never shift at DST boundaries.
  """

  @enforce_keys [:label, :start_date, :end_date]
  defstruct @enforce_keys

  @topic "deadline"
  @days_per_week_block 8

  def subscribe, do: Phoenix.PubSub.subscribe(WaveDashboard.PubSub, @topic)

  def today, do: :calendar.local_time() |> elem(0) |> Date.from_erl!()

  @doc "Returns the saved deadline, `:missing`, or `:corrupt` when the file cannot be read back."
  def load do
    with {:ok, contents} <- File.read(path()),
         {:ok, %{"version" => 1, "label" => label, "start_date" => start, "end_date" => finish}} <-
           JSON.decode(contents),
         {:ok, deadline} <- build(label, start, finish) do
      deadline
    else
      {:error, :enoent} -> :missing
      _corrupt -> :corrupt
    end
  end

  @doc "Saves a deadline from form input, keeping the start date of the current one."
  def save(label, end_date) do
    start_date =
      case load() do
        %__MODULE__{start_date: start_date} -> Date.to_iso8601(start_date)
        _none -> Date.to_iso8601(today())
      end

    with {:ok, deadline} <- build(label, start_date, end_date) do
      contents =
        JSON.encode!(%{
          "version" => 1,
          "label" => deadline.label,
          "start_date" => Date.to_iso8601(deadline.start_date),
          "end_date" => Date.to_iso8601(deadline.end_date)
        })

      WaveDashboard.State.write!(path(), contents)
      broadcast()
      {:ok, deadline}
    end
  end

  def reset do
    case File.rm(path()) do
      result when result in [:ok, {:error, :enoent}] -> broadcast()
      {:error, reason} -> {:error, reason}
    end
  end

  def expired?(%__MODULE__{end_date: end_date}, today), do: Date.after?(today, end_date)

  @doc "Total, elapsed (including today) and remaining days."
  def days(%__MODULE__{} = deadline, today) do
    total = Date.diff(deadline.end_date, deadline.start_date) + 1
    elapsed = max(0, Date.diff(today, deadline.start_date) + 1)
    remaining = max(0, Date.diff(deadline.end_date, today))
    {total, elapsed, remaining}
  end

  @doc "The deadline's days in blocks of eight, each day tagged as elapsed, today or future."
  def grid(%__MODULE__{} = deadline, today) do
    deadline.start_date
    |> Date.range(deadline.end_date)
    |> Enum.map(fn date -> {date, kind(date, today)} end)
    |> Enum.chunk_every(@days_per_week_block)
  end

  defp kind(date, today) do
    case Date.compare(date, today) do
      :lt -> :elapsed
      :eq -> :today
      :gt -> :future
    end
  end

  defp build(label, start_date, end_date) when is_binary(label) do
    label = String.trim(label)

    with {:label, true} <- {:label, label != "" and String.length(label) <= 200},
         {:ok, start_date} <- Date.from_iso8601(start_date),
         {:ok, end_date} <- Date.from_iso8601(end_date),
         {:order, true} <- {:order, not Date.before?(end_date, start_date)} do
      {:ok, %__MODULE__{label: label, start_date: start_date, end_date: end_date}}
    else
      {:label, false} -> {:error, "Label can't be blank"}
      {:order, false} -> {:error, "End date must be on or after the start date"}
      {:error, _reason} -> {:error, "End date is invalid"}
    end
  end

  defp build(_label, _start_date, _end_date), do: {:error, "Label can't be blank"}

  defp broadcast, do: Phoenix.PubSub.broadcast(WaveDashboard.PubSub, @topic, :deadline_changed)

  defp path, do: Path.join(Application.fetch_env!(:wave_dashboard, :state_dir), "deadline.json")
end
