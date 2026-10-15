defmodule Fugate.Scheduler do
  @moduledoc """
  Owns every run state change made outside the API, so the lifecycle of a run
  is never driven by two processes at once.

  It fires due jobs, wakes waiting runs, dispatches queued runs to hosts and
  settles agent turns reported by Herdr events. Work that needs Herdr waits
  until the event stream is connected and the active runs are reconciled.
  """
  use GenServer
  require Logger

  alias Fugate.{HostSelector, RunLifecycle}
  alias Fugate.Scheduling.{Job, Run, RunEvent}

  @max_sleep 60_000
  @min_sleep 100
  # The hook reports tokens shortly after Herdr emits the turn event.
  @token_attempts 5
  @token_retry 1_000
  @reconcile_retry 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Re-evaluates due work soon, e.g. after an API change."
  def poke, do: GenServer.cast(__MODULE__, :poke)

  def herdr_connected, do: GenServer.cast(__MODULE__, :herdr_connected)
  def herdr_disconnected, do: GenServer.cast(__MODULE__, :herdr_disconnected)
  def herdr_event(event, data), do: GenServer.cast(__MODULE__, {:herdr_event, event, data})

  @impl true
  def init(_opts) do
    selector = Application.fetch_env!(:fugate, :host_selector)

    state = %{
      timer: nil,
      herdr_ready: false,
      selector: selector,
      selector_state: selector.init(),
      # run id => latest {turn, message} reported while that run's turn is being settled
      settling: %{}
    }

    {:ok, state, {:continue, :tick}}
  end

  @impl true
  def handle_continue(:tick, state), do: {:noreply, tick(state)}

  @impl true
  def handle_cast(:poke, state), do: {:noreply, schedule(state, 0)}

  def handle_cast(:herdr_connected, state) do
    case reconcile_all(state) do
      {:ok, state} ->
        {:noreply, tick(%{state | herdr_ready: true})}

      {:error, reason} ->
        Logger.warning("Reconciliation failed, retrying: #{inspect(reason)}")
        Process.send_after(self(), :reconcile, @reconcile_retry)
        {:noreply, %{state | herdr_ready: false}}
    end
  end

  def handle_cast(:herdr_disconnected, state), do: {:noreply, %{state | herdr_ready: false}}

  def handle_cast({:herdr_event, "pane.turn_completed", data}, state) do
    {:noreply, turn_completed(state, data["pane"]["pane_id"], data["turn"], data["message"])}
  end

  def handle_cast({:herdr_event, "pane.agent_status_changed", data}, state) do
    if data["agent_status"] == "blocked" or data["input_pending"] == true do
      with %Run{} = run <- Run.placed_on_pane!(data["pane_id"]) do
        RunEvent.record!(run.id, "agent_attention", %{
          "agent_status" => data["agent_status"],
          "input_prompt_kind" => data["input_prompt_kind"]
        })
      end
    end

    {:noreply, state}
  end

  def handle_cast({:herdr_event, _event, _data}, state), do: {:noreply, state}

  @impl true
  def handle_info(:tick, state), do: {:noreply, tick(%{state | timer: nil})}
  def handle_info(:reconcile, state), do: handle_cast(:herdr_connected, state)

  def handle_info({:settle, run_id, turn, message, attempt}, state) do
    {:noreply, settle(state, run_id, turn, message, attempt)}
  end

  defp tick(state) do
    fire_due_jobs()

    state =
      if state.herdr_ready do
        Enum.each(Run.wake_due!(), &RunLifecycle.continue/1)
        dispatch(state)
      else
        state
      end

    schedule(state, next_delay(state))
  end

  defp fire_due_jobs do
    for job <- Job.due!() do
      case Run.active_for_job!(job.id) do
        nil ->
          with {:error, error} <- Run.schedule(job.id) do
            Logger.error("Could not queue job #{job.id}: #{Exception.message(error)}")
          end

        active ->
          RunEvent.record!(active.id, "schedule_skipped", %{
            "job_id" => job.id,
            "due_at" => job.next_run_at
          })
      end

      Job.advance!(job)
    end
  end

  defp dispatch(state) do
    case Run.queued!() do
      [] ->
        state

      queued ->
        load = Enum.frequencies_by(Run.placed!(), & &1.host)
        reachability = machine_reachability()

        {state, _load} =
          Enum.reduce(queued, {state, load}, fn run, {state, load} ->
            case HostSelector.candidates(run.job, load, reachability) do
              [] ->
                {state, load}

              candidates ->
                {host, selector_state} = state.selector.choose(candidates, state.selector_state)
                run = RunLifecycle.start(run, run.job, host)

                load =
                  if run.state in Run.placed_states(),
                    do: Map.update(load, host.name, 1, &(&1 + 1)),
                    else: load

                {%{state | selector_state: selector_state}, load}
            end
          end)

        state
    end
  end

  defp machine_reachability do
    if Enum.any?(Map.values(Fugate.Config.get().hosts), & &1.herdr_alias) do
      case Fugate.Herdr.machine_reachability() do
        {:ok, reachability} ->
          reachability

        {:error, reason} ->
          Logger.warning("Herdr machine.status failed: #{inspect(reason)}")
          %{}
      end
    else
      %{}
    end
  end

  defp reconcile_all(state) do
    with {:ok, %{"agents" => agents}} <- Fugate.Herdr.request("agent.list", %{}) do
      reachability = machine_reachability()

      state =
        for run <- Run.active!(),
            run.state != :queued,
            host_reachable?(run, reachability),
            reduce: state do
          state ->
            case RunLifecycle.reconcile(run, agents) do
              {_run, nil} -> state
              {run, turn} -> turn_completed(state, run.pane_id, turn, nil)
            end
        end

      {:ok, state}
    end
  end

  # An unreachable peer's agents may be missing from agent.list; its runs are
  # left untouched until the peer is reachable again.
  defp host_reachable?(%Run{host: host}, reachability) do
    case Fugate.Config.host(host) do
      nil -> true
      config_host -> HostSelector.reachable(config_host, reachability) != false
    end
  end

  defp turn_completed(state, pane_id, turn, message) do
    with %Run{} = run when run.state != :starting <- Run.placed_on_pane!(pane_id),
         true <- turn > (run.last_turn || 0) do
      case Map.fetch(state.settling, run.id) do
        {:ok, {pending, _message}} when pending >= turn ->
          state

        {:ok, _older} ->
          put_in(state.settling[run.id], {turn, message})

        :error ->
          send(self(), {:settle, run.id, turn, message, 1})
          put_in(state.settling[run.id], {turn, message})
      end
    else
      _ -> state
    end
  end

  defp settle(state, run_id, turn, message, attempt) do
    with {:ok, run} <- Ash.get(Run, run_id),
         true <- run.state in Run.placed_states() and run.state != :starting,
         true <- turn > (run.last_turn || 0) do
      case RunLifecycle.reported_status(run) do
        {:ok, status} ->
          RunLifecycle.apply_status(run, turn, status, "tokens")
          settled(state, run_id, turn)

        :none when attempt < @token_attempts ->
          Process.send_after(self(), {:settle, run_id, turn, message, attempt + 1}, @token_retry)
          state

        :none ->
          RunLifecycle.settle_unreported_turn(run, turn, message)
          settled(state, run_id, turn)
      end
    else
      _ -> settled(state, run_id, turn)
    end
  end

  defp settled(state, run_id, turn) do
    case Map.pop(state.settling, run_id) do
      {{latest, message}, settling} when latest > turn ->
        send(self(), {:settle, run_id, latest, message, 1})
        %{state | settling: Map.put(settling, run_id, {latest, message})}

      {_, settling} ->
        schedule(%{state | settling: settling}, 0)
    end
  end

  defp next_delay(state) do
    now = DateTime.utc_now()
    job = Job.next_due!()
    wake = if state.herdr_ready, do: Run.next_wake!()

    [job && job.next_run_at, wake && wake.wake_at]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&DateTime.diff(&1, now, :millisecond))
    |> Enum.min(fn -> @max_sleep end)
    |> min(@max_sleep)
  end

  defp schedule(state, delay) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :tick, max(delay, @min_sleep))}
  end
end
