defmodule Fugate.Readiness do
  @moduledoc """
  Whether an execution host can run a job in a repository unattended. Nothing
  is approved here; the owner approves on each host and Fugate only reads:

    * the repository is checked out there;
    * its worktrunk hooks, which run when a run's worktree is created, are
      approved (`wt config approvals add`);
    * Claude trusts the project root, which covers the repository and the
      worktrees beside it, so no run stops at Claude's folder trust question.

  Remote hosts are probed over SSH with their configured host name as target.
  """

  require Logger

  alias Fugate.Config.Host

  @probe_timeout 15_000

  # Prints the folders Claude trusts, then each repository's hook approval
  # state, for repositories given as home-relative paths.
  @probe ~S"""
  state="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
  printf 'trusted\t'
  jq -c '[(.projects // {}) | to_entries[] | select(.value.hasTrustDialogAccepted == true) | .key]' "$state" 2>/dev/null || echo '[]'
  for repo in "$@"; do
    if [ -d "$HOME/$repo/.git" ]; then
      approvals=$(wt -C "$HOME/$repo" config approvals list --format json 2>/dev/null | jq -r '.state')
      printf 'repo\t%s\t%s\n' "$repo" "${approvals:-unknown}"
    else
      printf 'repo\t%s\tmissing\n' "$repo"
    fi
  done
  """

  @type probe :: %{trusted: [String.t()], repos: %{String.t() => String.t()}} | :unreachable

  @doc "Probes every configured host for the given local paths, concurrently."
  @spec probe_hosts([String.t()]) :: %{String.t() => probe()}
  def probe_hosts(local_paths) do
    home = System.user_home!()

    repos =
      local_paths
      |> Enum.map(&Path.relative_to(&1, home))
      |> Enum.reject(&(Path.type(&1) == :absolute))

    hosts = Map.values(Fugate.Config.get().hosts)

    hosts
    |> Task.async_stream(&probe(&1, repos), timeout: @probe_timeout, on_timeout: :kill_task)
    |> Enum.zip(hosts)
    |> Map.new(fn
      {{:ok, probe}, host} -> {host.name, probe}
      {{:exit, _timeout}, host} -> {host.name, :unreachable}
    end)
  end

  @doc "What keeps `host` from running a job in `local_path`; empty when ready."
  @spec problems(probe(), Host.t(), String.t()) :: [String.t()]
  def problems(:unreachable, _host, _local_path), do: ["host unreachable"]

  def problems(probe, host, local_path) do
    path = Host.path(host, local_path)

    if local_path == Fugate.Scheduling.Repository.Read.without_project() do
      trust_problems(probe, [path, Path.join("/private", path)])
    else
      repo_problems(probe, Path.relative_to(local_path, System.user_home!())) ++
        trust_problems(probe, [Path.dirname(path)])
    end
  end

  defp repo_problems(probe, relative) do
    case Map.get(probe.repos, relative, "missing") do
      state when state in ["approved", "no_commands"] -> []
      "missing" -> ["not checked out"]
      "approval_required" -> ["worktrunk hooks not approved"]
      other -> ["worktrunk hooks: #{other}"]
    end
  end

  # Any of `folders`, or a folder above them, being trusted is enough.
  defp trust_problems(probe, folders) do
    trusted? =
      Enum.any?(probe.trusted, fn trusted ->
        Enum.any?(folders, &(&1 == trusted or String.starts_with?(&1, trusted <> "/")))
      end)

    if trusted?, do: [], else: ["folder not trusted in Claude"]
  end

  defp probe(host, repos) do
    {command, args} =
      if host.herdr_alias == nil,
        do: {"sh", ["-c", @probe, "fugate-probe" | repos]},
        else:
          {"ssh",
           [
             "-o",
             "BatchMode=yes",
             "-o",
             "ConnectTimeout=5",
             host.name,
             Enum.map_join(["sh", "-c", @probe, "fugate-probe" | repos], " ", &shell_quote/1)
           ]}

    case System.cmd(command, args) do
      {output, 0} ->
        parse(output)

      {output, status} ->
        Logger.warning("Readiness probe of #{host.name} exited #{status}: #{output}")
        :unreachable
    end
  end

  defp parse(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{trusted: [], repos: %{}}, fn line, probe ->
      case String.split(line, "\t") do
        ["trusted", json] -> %{probe | trusted: JSON.decode!(json)}
        ["repo", repo, state] -> put_in(probe.repos[repo], state)
        _other -> probe
      end
    end)
  end

  defp shell_quote(argument), do: "'" <> String.replace(argument, "'", ~S('\'')) <> "'"
end
