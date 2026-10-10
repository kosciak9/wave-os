defmodule WaveDashboard.Apps do
  @moduledoc """
  Apps that hosts expose through the dashboard.

  The registry file is the source of truth: Caddy's routes are derived from it
  and restored whenever Caddy's running configuration drifts, for example after
  a restart or a reload of its static configuration.
  """
  use GenServer
  require Logger

  alias WaveDashboard.{Caddy, Tailnet}

  @check_interval :timer.seconds(15)
  @connect_timeout :timer.seconds(2)
  @topic "apps"

  defmodule App do
    @moduledoc false
    @enforce_keys [:host, :project, :branch, :address, :port]
    defstruct @enforce_keys ++ [status: :unknown]

    def key(%__MODULE__{} = app), do: {app.host, app.project, app.branch}

    def hostname(%__MODULE__{} = app, domain),
      do: Enum.join([app.branch, app.project, app.host, domain], ".")
  end

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(WaveDashboard.PubSub, @topic)

  def list, do: GenServer.call(__MODULE__, :list)

  def url(%App{} = app), do: "https://" <> App.hostname(app, domain())

  @doc "Registers an app of the tailnet device calling from `address`; registering again replaces the port."
  def register(address, project, branch, port) do
    with {:ok, host} <- caller_host(address),
         {:ok, project} <- label(project),
         {:ok, branch} <- label(branch),
         :ok <- validate_port(port) do
      app = %App{host: host.name, project: project, branch: branch, address: address, port: port}
      GenServer.call(__MODULE__, {:register, app})
    end
  end

  def unregister(address, project, branch) do
    with {:ok, host} <- caller_host(address),
         {:ok, project} <- label(project),
         {:ok, branch} <- label(branch) do
      GenServer.call(__MODULE__, {:unregister, {host.name, project, branch}})
    end
  end

  @doc "Turns a project or branch name into a DNS label, as worktree tooling sanitizes branch names."
  def label(name) when is_binary(name) do
    label =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 63)
      |> String.trim_trailing("-")

    if label == "", do: {:error, :invalid_name}, else: {:ok, label}
  end

  def label(_name), do: {:error, :invalid_name}

  defp validate_port(port) when is_integer(port) and port in 1..65_535, do: :ok
  defp validate_port(_port), do: {:error, :invalid_port}

  defp caller_host(address) do
    case Tailnet.host_for_address(address) do
      {:ok, host} -> {:ok, host}
      :error -> {:error, :unknown_host}
    end
  end

  defp domain, do: Application.fetch_env!(:wave_dashboard, :domain)

  @impl true
  def init(nil) do
    {:ok, %{apps: load(), check: nil}, {:continue, :sync}}
  end

  @impl true
  def handle_continue(:sync, state) do
    send(self(), :check)
    {:noreply, sync_caddy(state)}
  end

  @impl true
  def handle_call(:list, _from, state), do: {:reply, sorted(state.apps), state}

  def handle_call({:register, app}, _from, state) do
    apps = Map.put(state.apps, App.key(app), app)
    {:reply, {:ok, app}, changed(state, apps)}
  end

  def handle_call({:unregister, key}, _from, state) do
    case Map.pop(state.apps, key) do
      {nil, _apps} -> {:reply, {:error, :not_found}, state}
      {_app, apps} -> {:reply, :ok, changed(state, apps)}
    end
  end

  @impl true
  def handle_info(:check, %{check: nil} = state) do
    Process.send_after(self(), :check, @check_interval)
    targets = Enum.map(state.apps, fn {key, app} -> {key, app.address, app.port} end)
    task = Task.async(fn -> Map.new(targets, &check/1) end)
    {:noreply, sync_caddy(%{state | check: task.ref})}
  end

  def handle_info(:check, state) do
    Process.send_after(self(), :check, @check_interval)
    {:noreply, state}
  end

  def handle_info({ref, statuses}, %{check: ref} = state) do
    Process.demonitor(ref, [:flush])

    apps =
      Map.new(state.apps, fn {key, app} ->
        {key, %{app | status: Map.get(statuses, key, app.status)}}
      end)

    if apps != state.apps, do: publish(apps)
    {:noreply, %{state | apps: apps, check: nil}}
  end

  defp check({key, address, port}) do
    {:ok, ip} = address |> String.to_charlist() |> :inet.parse_address()

    case :gen_tcp.connect(ip, port, [], @connect_timeout) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        {key, :up}

      {:error, _reason} ->
        {key, :down}
    end
  end

  defp changed(state, apps) do
    save(apps)
    publish(apps)
    sync_caddy(%{state | apps: apps})
  end

  defp sync_caddy(state) do
    case Caddy.sync(Map.values(state.apps)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Caddy sync failed: #{inspect(reason)}")
    end

    state
  end

  defp publish(apps),
    do: Phoenix.PubSub.broadcast(WaveDashboard.PubSub, @topic, {:apps, sorted(apps)})

  defp sorted(apps), do: apps |> Map.values() |> Enum.sort_by(&{&1.project, &1.host, &1.branch})

  defp path, do: Path.join(Application.fetch_env!(:wave_dashboard, :state_dir), "apps.json")

  defp load do
    case File.read(path()) do
      {:ok, contents} ->
        contents
        |> JSON.decode!()
        |> Map.new(fn entry ->
          app = %App{
            host: entry["host"],
            project: entry["project"],
            branch: entry["branch"],
            address: entry["address"],
            port: entry["port"]
          }

          {App.key(app), app}
        end)

      {:error, :enoent} ->
        %{}
    end
  end

  defp save(apps) do
    entries =
      apps
      |> sorted()
      |> Enum.map(&Map.take(&1, [:host, :project, :branch, :address, :port]))

    WaveDashboard.State.write!(path(), JSON.encode!(entries))
  end
end
