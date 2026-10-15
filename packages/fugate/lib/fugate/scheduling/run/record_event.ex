defmodule Fugate.Scheduling.Run.RecordEvent do
  @moduledoc """
  Records a run event in the same transaction as the run change. The kind comes
  from the `kind` option or the action's `event` argument; state changes are
  included in the event data.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    kind = opts[:kind] || Ash.Changeset.get_argument(changeset, :event)
    data = Ash.Changeset.get_argument(changeset, :event_data) || %{}
    from = changeset.data.state

    Ash.Changeset.after_action(changeset, fn _changeset, run ->
      data =
        if changeset.action_type == :create or from != run.state,
          do: Map.merge(data, %{"state" => run.state}),
          else: data

      Fugate.Scheduling.RunEvent.record!(run.id, kind, data)
      {:ok, run}
    end)
  end
end
