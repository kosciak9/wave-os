defmodule WaveDashboard.Tailnet do
  @moduledoc """
  The owner's devices on the tailnet, read from `tailscale status`.

  A device's name is the first label of its MagicDNS name, which is also the
  host label in app domains.
  """
  use GenServer
  require Logger

  @refresh_interval :timer.seconds(15)
  @topic "tailnet"

  defmodule Host do
    @moduledoc false
    @enforce_keys [:name, :os, :online?, :last_seen, :addresses]
    defstruct @enforce_keys
  end

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(WaveDashboard.PubSub, @topic)

  def hosts, do: GenServer.call(__MODULE__, :hosts)

  @doc "Finds the owner's device using a tailnet address, refreshing once for devices that just joined."
  def host_for_address(address), do: GenServer.call(__MODULE__, {:host_for_address, address})

  @impl true
  def init(nil) do
    send(self(), :refresh)
    {:ok, []}
  end

  @impl true
  def handle_call(:hosts, _from, hosts), do: {:reply, hosts, hosts}

  def handle_call({:host_for_address, address}, _from, hosts) do
    case find_by_address(hosts, address) do
      %Host{} = host ->
        {:reply, {:ok, host}, hosts}

      nil ->
        hosts = refresh(hosts)

        case find_by_address(hosts, address) do
          %Host{} = host -> {:reply, {:ok, host}, hosts}
          nil -> {:reply, :error, hosts}
        end
    end
  end

  @impl true
  def handle_info(:refresh, hosts) do
    Process.send_after(self(), :refresh, @refresh_interval)
    {:noreply, refresh(hosts)}
  end

  defp find_by_address(hosts, address), do: Enum.find(hosts, &(address in &1.addresses))

  defp refresh(hosts) do
    case System.cmd("tailscale", ["status", "--json"], stderr_to_stdout: true) do
      {output, 0} ->
        output |> JSON.decode!() |> parse_status() |> publish_changes(hosts)

      {output, status} ->
        Logger.warning("tailscale status exited with #{status}: #{output}")
        hosts
    end
  end

  defp publish_changes(hosts, hosts), do: hosts

  defp publish_changes(new_hosts, _old_hosts) do
    Phoenix.PubSub.broadcast(WaveDashboard.PubSub, @topic, {:hosts, new_hosts})
    new_hosts
  end

  defp parse_status(%{"Self" => self_node, "Peer" => peers}) do
    owner = self_node["UserID"]

    peers
    |> Map.values()
    |> Enum.filter(&(&1["UserID"] == owner))
    |> Enum.map(&host(&1, &1["Online"]))
    |> then(&[host(self_node, true) | &1])
    |> Enum.sort_by(& &1.name)
  end

  defp host(node, online?) do
    %Host{
      name: node["DNSName"] |> String.split(".") |> hd(),
      os: node["OS"],
      online?: online? == true,
      last_seen: last_seen(node["LastSeen"]),
      addresses: node["TailscaleIPs"]
    }
  end

  # Tailscale reports the zero time for devices that are connected now.
  defp last_seen(nil), do: nil
  defp last_seen("0001-01-01" <> _), do: nil

  defp last_seen(timestamp) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(timestamp)
    datetime
  end
end
