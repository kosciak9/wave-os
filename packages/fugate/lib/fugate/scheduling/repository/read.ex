defmodule Fugate.Scheduling.Repository.Read do
  @moduledoc """
  Lists the git checkouts directly inside the configured project roots, after
  the scratch directory for jobs without a project, each with its readiness
  on every execution host. Linked worktrees (whose `.git` is a file) and hidden
  directories are skipped.
  """
  use Ash.Resource.ManualRead

  alias Fugate.Scheduling.Repository

  @without_project "/tmp"

  @doc "The directory a job without a project runs in, the same on every host."
  def without_project, do: @without_project

  @impl true
  def read(_query, _data_layer_query, _opts, _context), do: {:ok, repositories()}

  @spec repositories() :: [Repository.t()]
  def repositories do
    repositories =
      for root <- Fugate.Config.get().project_roots,
          path <- Path.wildcard(Path.join(root, "*")),
          File.dir?(Path.join(path, ".git")) do
        %Repository{id: Path.relative_to(path, Path.dirname(root)), path: path}
      end

    repositories = [
      %Repository{id: "Without project", path: @without_project}
      | Enum.sort_by(repositories, & &1.id)
    ]

    probes = Fugate.Readiness.probe_hosts(Enum.map(repositories, & &1.path))
    hosts = Fugate.Config.get().hosts

    for repository <- repositories do
      readiness =
        Map.new(probes, fn {name, probe} ->
          {name, Fugate.Readiness.problems(probe, hosts[name], repository.path)}
        end)

      %{repository | readiness: readiness}
    end
  end
end
