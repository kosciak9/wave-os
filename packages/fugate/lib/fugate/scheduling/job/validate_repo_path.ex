defmodule Fugate.Scheduling.Job.ValidateRepoPath do
  @moduledoc """
  The repository must be one of the checkouts offered in the project roots and
  ready on every allowed host. Claude's folder trust matters only to Claude.
  """
  use Ash.Resource.Validation

  alias Fugate.Scheduling.Repository

  @impl true
  def validate(changeset, _opts, _context) do
    if Enum.any?(
         [:repo_path, :allowed_hosts, :harness],
         &Ash.Changeset.changing_attribute?(changeset, &1)
       ),
       do: validate_ready(changeset),
       else: :ok
  end

  defp validate_ready(changeset) do
    repo_path = Ash.Changeset.get_attribute(changeset, :repo_path)
    harness = Ash.Changeset.get_attribute(changeset, :harness)
    hosts = Ash.Changeset.get_attribute(changeset, :allowed_hosts) || []

    case Enum.find(Repository.Read.repositories(), &(&1.path == repo_path)) do
      nil ->
        {:error, field: :repo_path, message: "must be a repository in the project roots"}

      repository ->
        problems =
          for host <- hosts,
              problem <- Map.get(repository.readiness, host, []),
              harness == :claude or problem != "folder not trusted in Claude",
              do: "#{host}: #{problem}"

        if problems == [],
          do: :ok,
          else: {:error, field: :repo_path, message: "not ready on " <> Enum.join(problems, ", ")}
    end
  end
end
