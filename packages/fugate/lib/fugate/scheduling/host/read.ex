defmodule Fugate.Scheduling.Host.Read do
  @moduledoc false
  use Ash.Resource.ManualRead

  alias Fugate.Scheduling.{Host, Run}

  @impl true
  def read(_query, _data_layer_query, _opts, _context) do
    active_runs = Run.placed!() |> Enum.frequencies_by(& &1.host)

    reachability =
      case Fugate.Herdr.machine_reachability() do
        {:ok, reachability} -> reachability
        {:error, _} -> %{}
      end

    hosts =
      for {name, host} <- Enum.sort(Fugate.Config.get().hosts) do
        %Host{
          id: name,
          name: name,
          reachable: Fugate.HostSelector.reachable(host, reachability),
          harnesses: host.harnesses,
          max_concurrent: host.max_concurrent,
          active_runs: Map.get(active_runs, name, 0)
        }
      end

    {:ok, hosts}
  end
end
