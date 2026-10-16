defmodule Fugate.Scheduling.Run.ArchiveAgent do
  @moduledoc """
  Archives the run's agent in Herdr before the run is marked archived. An agent
  Herdr cannot archive (it exited, or never reported a resumable session) has
  its workspace closed instead.
  """
  use Ash.Resource.Change

  alias Fugate.Herdr

  @unarchivable ~w(agent_not_found no_resumable_session)

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      run = changeset.data

      case Herdr.archive_agent(run.pane_id) do
        :ok -> changeset
        {:error, %{"code" => code}} when code in @unarchivable -> close_workspace(changeset, run)
        {:error, reason} -> failed(changeset, reason)
      end
    end)
  end

  defp close_workspace(changeset, run) do
    case Herdr.close_workspace(run.workspace_id) do
      :ok -> changeset
      {:error, %{"code" => "workspace_not_found"}} -> changeset
      {:error, reason} -> failed(changeset, reason)
    end
  end

  defp failed(changeset, reason),
    do:
      Ash.Changeset.add_error(changeset, "Herdr could not close the session: #{inspect(reason)}")
end
