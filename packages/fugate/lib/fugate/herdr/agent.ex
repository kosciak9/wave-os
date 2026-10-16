defmodule Fugate.Herdr.Agent do
  @moduledoc """
  The parts of a Herdr agent Fugate relies on.

  `completed_turn` is `{turn_epoch, turn}` of the last completed turn. Herdr
  restarts a pane's turn counter under a new epoch (for example after a server
  restart), so turns are only comparable within one epoch.
  """

  @enforce_keys [
    :pane_id,
    :terminal_id,
    :name,
    :kind,
    :session,
    :status,
    :launch_pending,
    :interactive_ready,
    :completed_turn,
    :tokens
  ]
  defstruct @enforce_keys

  @type turn :: {epoch :: non_neg_integer() | nil, turn :: non_neg_integer()}

  @type t :: %__MODULE__{
          pane_id: String.t(),
          terminal_id: String.t(),
          name: String.t() | nil,
          kind: String.t() | nil,
          session: String.t() | nil,
          status: String.t() | nil,
          launch_pending: boolean(),
          interactive_ready: boolean(),
          completed_turn: turn(),
          tokens: %{String.t() => String.t()}
        }

  @spec parse(term()) :: {:ok, t()} | :error
  def parse(%{"pane_id" => pane_id, "terminal_id" => terminal_id} = agent)
      when is_binary(pane_id) and is_binary(terminal_id) do
    {:ok,
     %__MODULE__{
       pane_id: pane_id,
       terminal_id: terminal_id,
       name: string(agent["name"]),
       kind: string(agent["agent"]),
       session: agent |> Map.get("agent_session") |> session(),
       status: string(agent["agent_status"]),
       launch_pending: agent["launch_pending"] == true,
       interactive_ready: agent["interactive_ready"] == true,
       completed_turn: completed_turn(agent),
       tokens: tokens(agent["tokens"])
     }}
  end

  def parse(_agent), do: :error

  @doc """
  Whether `turn` completed after `previous`. A turn in a different epoch than
  `previous` is new: the counter was restarted after `previous` was recorded.
  """
  @spec turn_after?(turn(), turn()) :: boolean()
  def turn_after?({epoch, turn}, {epoch, previous}), do: turn > previous
  def turn_after?({_epoch, turn}, {_previous_epoch, _previous}), do: turn > 0

  defp completed_turn(%{"last_completed_turn" => %{"turn" => turn, "turn_epoch" => epoch}})
       when is_integer(turn) and is_integer(epoch),
       do: {epoch, turn}

  defp completed_turn(%{"turn_epoch" => epoch}) when is_integer(epoch), do: {epoch, 0}
  defp completed_turn(_agent), do: {nil, 0}

  defp session(%{"value" => value}) when is_binary(value), do: value
  defp session(_session), do: nil

  defp tokens(tokens) when is_map(tokens),
    do:
      for(
        {key, value} <- tokens,
        is_binary(key) and is_binary(value),
        into: %{},
        do: {key, value}
      )

  defp tokens(_tokens), do: %{}

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil
end
