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
  alias Fugate.Herdr.Agent
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
      reconcile_timer: nil,
      herdr_ready: false,
      selector: selector,
      selector_state: selector.init(),
      # run id => latest {{epoch, turn}, message} reported while that run's turn is being settled
      settling: %{}
    }

    {:ok, state, {:continue, :tick}}
  end

  @impl true
  def handle_continue(:tick, state), do: {:noreply, tick(state)}

  @impl true
  def handle_cast(:poke, state), do: {:noreply, schedule(state, 0)}

  def handle_cast(:herdr_connected, state), do: {:noreply, reconcile(state)}

  def handle_cast(:herdr_disconnected, state),
    do: {:noreply, %{cancel_reconcile(state) | herdr_ready: false}}

  def handle_cast(
        {:herdr_event, "pane.turn_completed",
         %{"pane" => %{"pane_id" => pane_id}, "turn" => turn, "turn_epoch" => epoch} = data},
        state
      )
      when is_binary(pane_id) and is_integer(turn) and is_integer(epoch) do
    {:noreply, turn_completed(state, pane_id, {epoch, turn}, data["message"])}
  end

  def handle_cast(
        {:herdr_event, "pane.agent_status_changed", %{"pane_id" => pane_id} = data},
        state
      )
      when is_binary(pane_id) do
    with true <- needs_attention?(data),
         %Run{} = run <- Run.placed_on_pane!(pane_id) do
      RunEvent.record!(run.id, "agent_attention", %{
        "agent_status" => data["agent_status"],
        "input_prompt_kind" => data["input_prompt_kind"]
      })
    end

    {:noreply, state}
  end

  def handle_cast({:herdr_event, _event, _data}, state), do: {:noreply, state}

  @impl true
  def handle_info(:tick, state), do: {:noreply, tick(%{state | timer: nil})}
  def handle_info(:reconcile, state), do: {:noreply, reconcile(%{state | reconcile_timer: nil})}

  def handle_info({:settle, run_id, turn, message, attempt}, state) do
    {:noreply, settle(state, run_id, turn, message, attempt)}
  end

  defp needs_attention?(%{"agent_status" => "blocked"}), do: true
  defp needs_attention?(%{"input_pending" => true}), do: true
  defp needs_attention?(_status), do: false

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

                load =
                  case RunLifecycle.start(run, run.job, host) do
                    {:ok, %Run{state: :running}} -> Map.update(load, host.name, 1, &(&1 + 1))
                    {:ok, %Run{state: :failed}} -> load
                    {:error, :not_active} -> load
                  end

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

  defp reconcile(state) do
    state = cancel_reconcile(state)

    case reconcile_all(state) do
      {:ok, state} ->
        tick(%{state | herdr_ready: true})

      {:error, reason} ->
        Logger.warning("Reconciliation failed, retrying: #{inspect(reason)}")
        timer = Process.send_after(self(), :reconcile, @reconcile_retry)
        %{state | herdr_ready: false, reconcile_timer: timer}
    end
  end

  defp cancel_reconcile(%{reconcile_timer: nil} = state), do: state

  defp cancel_reconcile(state) do
    Process.cancel_timer(state.reconcile_timer)
    %{state | reconcile_timer: nil}
  end

  defp reconcile_all(state) do
    with {:ok, agents} <- Fugate.Herdr.list_agents() do
      reachability = machine_reachability()

      state =
        for run <- Run.active!(),
            run.state != :queued,
            host_reachable?(run, reachability),
            reduce: state do
          state ->
            case RunLifecycle.reconcile(run, agents) do
              {:ok, run, {_epoch, _turn} = turn} ->
                turn_completed(state, run.pane_id, turn, nil)

              {:ok, _run, nil} ->
                state

              {:error, :not_active} ->
                state
            end
        end

      {:ok, state}
    end
  end

  # An unreachable peer's agents may be missing from agent.list; its runs are
  # left untouched until the peer is reachable again.
  defp host_reachable?(%Run{host: host}, reachability),
    do: host |> Fugate.Config.host() |> configured_host_reachable?(reachability)

  defp configured_host_reachable?(nil = _unconfigured, _reachability), do: true

  defp configured_host_reachable?(host, reachability),
    do: HostSelector.reachable(host, reachability) != false

  defp turn_completed(state, pane_id, turn, message) do
    with %Run{} = run when run.state != :starting <- Run.placed_on_pane!(pane_id),
         true <- RunLifecycle.new_turn?(run, turn) do
      case Map.fetch(state.settling, run.id) do
        :error ->
          send(self(), {:settle, run.id, turn, message, 1})
          put_in(state.settling[run.id], {turn, message})

        {:ok, {pending, _message}} ->
          if Agent.turn_after?(turn, pending),
            do: put_in(state.settling[run.id], {turn, message}),
            else: state
      end
    else
      _not_new -> state
    end
  end

  defp settle(state, run_id, turn, message, attempt) do
    with {:ok, run} <- Ash.get(Run, run_id),
         true <- run.state in Run.placed_states() and run.state != :starting,
         true <- RunLifecycle.new_turn?(run, turn) do
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
      _settled_or_gone -> settled(state, run_id, turn)
    end
  end

  defp settled(state, run_id, turn) do
    {{latest, message}, settling} = Map.pop(state.settling, run_id)

    if Agent.turn_after?(latest, turn) do
      send(self(), {:settle, run_id, latest, message, 1})
      %{state | settling: Map.put(settling, run_id, {latest, message})}
    else
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
