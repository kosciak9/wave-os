defmodule Fugate.Scheduling.Repository.Read do
  @moduledoc """
  Lists checkouts one or two levels below `~/Developer` (`project` or
  `owner/project`); hidden directories such as `.worktrees` are skipped.
  """
  use Ash.Resource.ManualRead

  alias Fugate.Scheduling.Repository

  @impl true
  def read(_query, _data_layer_query, _opts, _context) do
    root = Path.join(System.user_home!(), "Developer")

    repositories =
      for pattern <- ["*", "*/*"],
          path <- Path.wildcard(Path.join(root, pattern)),
          File.exists?(Path.join(path, ".git")) do
        %Repository{id: Path.relative_to(path, root), path: path}
      end

    {:ok, Enum.sort_by(repositories, & &1.id)}
  end
end
