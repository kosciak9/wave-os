defmodule Fugate.StatusLine do
  @moduledoc """
  The run status an agent reports at the end of every turn, either as the
  `fugate: <status> run=<id>[ until=<iso8601>]` line or as the Herdr metadata
  tokens the hook derives from it.
  """

  @enforce_keys [:status, :run_id, :until]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          status: :completed | :waiting | :blocked | :failed,
          run_id: String.t(),
          until: DateTime.t() | nil
        }

  @pattern ~r/^fugate:\s+(completed|waiting|blocked|failed)\s+run=(\S+)(?:\s+until=(\S+))?$/
  @statuses %{
    "completed" => :completed,
    "waiting" => :waiting,
    "blocked" => :blocked,
    "failed" => :failed
  }

  @doc "Parses one line, tolerating surrounding backticks and whitespace."
  @spec parse_line(String.t()) :: {:ok, t()} | :error
  def parse_line(line) do
    case Regex.run(@pattern, line |> String.trim() |> String.trim("`") |> String.trim()) do
      [_, status, run_id] -> build(status, run_id, nil)
      [_, status, run_id, until] -> build(status, run_id, until)
      nil -> :error
    end
  end

  @doc "The last status line in `text` that belongs to `run_id`."
  @spec find_last(String.t() | nil, String.t()) :: {:ok, t()} | :error
  def find_last(nil, _run_id), do: :error

  def find_last(text, run_id) do
    text
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find_value(:error, fn line ->
      case parse_line(line) do
        {:ok, %{run_id: ^run_id}} = found -> found
        _ -> nil
      end
    end)
  end

  @doc """
  Reads the hook tokens of an agent. Tokens count only for `run_id` and when
  reported at or after `since`, so a previous turn's report is never reused.
  """
  @spec from_tokens(map(), String.t(), DateTime.t() | nil) :: {:ok, t()} | :error
  def from_tokens(
        %{"fugate_status" => status, "fugate_run" => run_id, "fugate_at" => at} = tokens,
        run_id,
        since
      ) do
    with {at_ms, ""} <- Integer.parse(at),
         true <- since == nil or at_ms >= DateTime.to_unix(since, :millisecond) do
      build(status, run_id, tokens["fugate_until"])
    else
      _ -> :error
    end
  end

  def from_tokens(_tokens, _run_id, _since), do: :error

  defp build(status, run_id, until) do
    with {:ok, status} <- Map.fetch(@statuses, status),
         {:ok, until} <- parse_until(status, until) do
      {:ok, %__MODULE__{status: status, run_id: run_id, until: until}}
    end
  end

  defp parse_until(:waiting, until) when is_binary(until) do
    case DateTime.from_iso8601(until) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _} -> :error
    end
  end

  defp parse_until(:waiting, _missing), do: :error
  defp parse_until(_status, _until), do: {:ok, nil}
end
