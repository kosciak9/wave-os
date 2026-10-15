defmodule WaveDashboard.Fugate do
  @moduledoc """
  The last known state of the Fugate scheduler: hosts, jobs, active runs and
  the latest finished runs, polled in the background and broadcast whenever it
  changes.
  """
  use GenServer
  require Logger

  alias WaveDashboard.Fugate.Client

  @poll_interval :timer.seconds(5)
  @finished_runs 20
  @topic "fugate"

  defmodule Snapshot do
    @moduledoc """
    `status` is `:not_configured`, `:loading`, `:ok` or `{:error, reason}`;
    after an error the previous data is kept and shown as stale.
    """
    defstruct status: :loading,
              hosts: [],
              max_concurrent: nil,
              jobs: [],
              active_runs: [],
              finished_runs: []
  end

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(WaveDashboard.PubSub, @topic)

  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc "Polls now, after an action changed the scheduler's state."
  def refresh, do: send(__MODULE__, :poll)

  @impl true
  def init(nil) do
    if Client.configured?() do
      send(self(), :poll)
      {:ok, %{snapshot: %Snapshot{}, poll: nil, timer: nil}}
    else
      {:ok, %{snapshot: %Snapshot{status: :not_configured}, poll: nil, timer: nil}}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}

  @impl true
  def handle_info(:poll, %{snapshot: %Snapshot{status: :not_configured}} = state),
    do: {:noreply, state}

  # A refresh during a poll waits for the next one, which is at most one interval away.
  def handle_info(:poll, %{poll: nil} = state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    # Unlinked, so a response the client cannot parse never takes the dashboard down.
    task = Task.Supervisor.async_nolink(WaveDashboard.TaskSupervisor, &fetch/0)
    {:noreply, %{state | poll: task.ref, timer: nil}}
  end

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info({ref, result}, %{poll: ref} = state) do
    Process.demonitor(ref, [:flush])
    snapshot = apply_result(state.snapshot, result)
    if snapshot != state.snapshot, do: publish(snapshot)
    timer = Process.send_after(self(), :poll, @poll_interval)
    {:noreply, %{state | snapshot: snapshot, poll: nil, timer: timer}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{poll: ref} = state) do
    Logger.warning("Fugate poll crashed: #{inspect(reason)}")
    timer = Process.send_after(self(), :poll, @poll_interval)

    {:noreply,
     %{state | snapshot: %{state.snapshot | status: {:error, reason}}, poll: nil, timer: timer}}
  end

  defp fetch do
    with {:ok, hosts, max_concurrent} <- Client.hosts(),
         {:ok, jobs} <- Client.jobs(),
         {:ok, active_runs} <- Client.active_runs(),
         {:ok, finished_runs} <- Client.finished_runs(@finished_runs) do
      {:ok,
       %Snapshot{
         status: :ok,
         hosts: hosts,
         max_concurrent: max_concurrent,
         jobs: jobs,
         active_runs: active_runs,
         finished_runs: finished_runs
       }}
    end
  end

  defp apply_result(_snapshot, {:ok, snapshot}), do: snapshot

  defp apply_result(snapshot, {:error, reason}) do
    if snapshot.status != {:error, reason},
      do: Logger.warning("Fugate poll failed: #{inspect(reason)}")

    %{snapshot | status: {:error, reason}}
  end

  defp publish(snapshot),
    do: Phoenix.PubSub.broadcast(WaveDashboard.PubSub, @topic, {:fugate, snapshot})
end
