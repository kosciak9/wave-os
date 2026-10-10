defmodule WaveDashboard.State do
  @moduledoc false

  @doc "Replaces a state file atomically, so a crash never leaves it half written."
  def write!(path, contents) do
    temporary = path <> ".tmp"
    File.mkdir_p!(Path.dirname(path))
    File.write!(temporary, contents)
    File.rename!(temporary, path)
  end
end
