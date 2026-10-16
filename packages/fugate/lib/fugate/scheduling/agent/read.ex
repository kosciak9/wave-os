defmodule Fugate.Scheduling.Agent.Read do
  @moduledoc false
  use Ash.Resource.ManualRead

  alias Fugate.Scheduling.Agent

  @impl true
  def read(_query, _data_layer_query, _opts, _context) do
    # Herdr's aggregate view includes the agents it caches from federated machines.
    case Fugate.Herdr.request("agent.list", %{}) do
      {:ok, %{"agents" => agents}} when is_list(agents) ->
        local = local_machine()
        runs = Enum.reverse(Fugate.Scheduling.Run.with_session!())

        {:ok,
         for(
           %{"pane_id" => pane_id} = agent <- agents,
           do: agent(agent, pane_id, local, runs)
         )}

      {:ok, _unexpected} ->
        {:error, "Herdr sent an unexpected agent.list response"}

      {:error, reason} ->
        {:error, "Herdr is unavailable: #{inspect(reason)}"}
    end
  end

  defp agent(agent, pane_id, local, runs) do
    machine = agent["machine_label"] || local

    %Agent{
      id: "#{machine}/#{pane_id}",
      machine: machine,
      kind: agent["agent"],
      title: agent["terminal_title_stripped"],
      status: agent["agent_status"],
      status_since: since(agent["status_since_unix_ms"]),
      cwd: agent["cwd"],
      run_id: run_id(agent, machine, runs)
    }
  end

  defp run_id(agent, machine, runs) do
    with {:ok, identity} <- Fugate.Herdr.Agent.parse(agent),
         name when is_binary(name) <- identity.name do
      Enum.find_value(runs, fn run ->
        if run.host == machine and run.pane_id == identity.pane_id and
             run.agent_name == name and run.terminal_id == identity.terminal_id and
             run.agent_session == identity.session,
           do: run.id
      end)
    else
      _ -> nil
    end
  end

  # The configured host Fugate reaches without a Herdr machine alias is this one.
  defp local_machine do
    Enum.find_value(Fugate.Config.get().hosts, fn {name, host} ->
      if host.herdr_alias == nil, do: name
    end)
  end

  defp since(ms) when is_integer(ms), do: DateTime.from_unix!(ms, :millisecond)
  defp since(_ms), do: nil
end
