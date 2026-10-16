defmodule Fugate.RunLifecycle do
  @moduledoc """
  Drives a run's agent through Herdr. Every step is persisted (with its run
  event) before the next Herdr call, so after a crash reconciliation can tell
  what was done, and a prompt is never sent twice.
  """

  alias Fugate.{Herdr, StatusLine}
  alias Fugate.Herdr.Agent
  alias Fugate.Scheduling.{Job, Repository, Run, RunEvent}
  require Logger

  # Herdr gives up on a pending launch after the same time.
  @start_timeout 45_000
  @prompt_timeout 30_000
  @screen_lines 80

  # Events recording a prompt delivery; a "*_sending" one without its outcome
  # means the delivery was interrupted and its result is unknown.
  @delivery_events ~w(prompt_sent continuation_sending continuation_sent continuation_failed
                      status_check_sending status_check_sent status_check_failed)
  @interrupted_deliveries %{
    "continuation_sending" => "continuation_interrupted",
    "status_check_sending" => "status_check_interrupted"
  }

  @type result :: {:ok, Run.t()} | {:error, :not_active}

  @spec start(Run.t(), Job.t(), Fugate.Config.Host.t()) :: result()
  def start(run, job, host) do
    agent_name = "fugate-" <> (run.id |> String.replace("-", "") |> binary_part(0, 8))

    with {:ok, run} <-
           transition(run, "starting", %{
             state: :starting,
             host: host.name,
             agent_name: agent_name
           }) do
      case launch(run, job, host) do
        {:ok, %Run{}} = launched ->
          launched

        {:error, :not_active} = not_active ->
          not_active

        {:error, step, run, reason} ->
          transition(run, "start_failed", %{state: :failed, finished_at: now()}, %{
            "step" => step,
            "error" => format_error(reason)
          })
      end
    end
  end

  defp launch(run, job, host) do
    with {step_name, opened} = open_workspace(run, job, host),
         {:ok, created} <- step(run, step_name, opened),
         {:ok, run} <-
           transition(
             run,
             "workspace_created",
             Map.take(created, [:workspace_id, :pane_id]),
             created |> Map.take([:path, :branch]) |> Map.new(fn {k, v} -> {to_string(k), v} end)
           ),
         start = %{
           name: run.agent_name,
           kind: Atom.to_string(job.harness),
           pane_id: run.pane_id,
           timeout_ms: @start_timeout
         },
         :ok <- step(run, "pane.process_info", Herdr.await_shell(run.pane_id, @start_timeout)),
         :ok <- step(run, "agent.start", Herdr.start_agent(start)),
         {:ok, agent} <-
           step(run, "agent.get", Herdr.await_interactive(run.pane_id, @start_timeout)),
         {:ok, run} <-
           transition(
             run,
             "agent_started",
             agent
             |> agent_identity()
             |> Map.merge(turn_attrs(agent.completed_turn))
             |> Map.put(:checkpoint_at, now())
           ),
         text = preamble(run) <> job.prompt,
         {:ok, delivery} <-
           step(run, "agent.prompt", Herdr.prompt_agent(run.pane_id, text, @prompt_timeout)) do
      transition(run, "prompt_sent", %{state: :running}, %{"delivery" => delivery})
    end
  end

  # A job in a project works on a branch of its own, in a new worktree.
  defp open_workspace(run, job, host) do
    params =
      put_machine(
        %{
          cwd: Fugate.Config.Host.path(host, job.repo_path),
          label: "fugate: #{job.name}",
          focus: false
        },
        host
      )

    if job.repo_path == Repository.Read.without_project(),
      do: {"workspace.create", Herdr.create_workspace(params)},
      else: {"worktree.create", Herdr.create_worktree(Map.put(params, :branch, branch(run, job)))}
  end

  defp branch(run, job) do
    slug =
      job.name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)
      |> String.trim("-")

    "fugate/#{if slug == "", do: "run", else: slug}-#{binary_part(run.id, 0, 8)}"
  end

  defp put_machine(params, %{herdr_alias: nil}), do: params
  defp put_machine(params, %{herdr_alias: alias}), do: Map.put(params, :machine, alias)

  defp step(_run, _name, :ok), do: :ok
  defp step(_run, _name, {:ok, result}), do: {:ok, result}
  defp step(run, name, {:error, reason}), do: {:error, name, run, reason}

  @doc "Sends the scheduled continuation of a waiting run."
  @spec continue(Run.t()) :: result()
  def continue(run) do
    wake_at = run.wake_at

    with {:ok, run} <-
           transition(
             run,
             "continuation_sending",
             %{state: :running, wake_at: nil, checkpoint_at: now()},
             %{"wake_at" => wake_at}
           ) do
      text =
        "Fugate: continue run #{run.id} now (scheduled continuation at #{DateTime.to_iso8601(wake_at)}). " <>
          "End with the status line."

      case Herdr.prompt_agent(run.pane_id, text, @prompt_timeout) do
        {:ok, delivery} ->
          transition(run, "continuation_sent", %{}, %{"delivery" => delivery})

        {:error, reason} ->
          transition(run, "continuation_failed", %{state: :blocked}, %{
            "error" => format_error(reason)
          })
      end
    end
  end

  @doc "Whether `turn` completed after the last turn the run has settled."
  @spec new_turn?(Run.t(), Agent.turn()) :: boolean()
  def new_turn?(run, turn), do: Agent.turn_after?(turn, {run.turn_epoch, run.last_turn || 0})

  @doc "The status the hook reported for the latest turn, if it has landed yet."
  @spec reported_status(Run.t()) :: {:ok, StatusLine.t()} | :none
  def reported_status(run) do
    with {:ok, agent} <- Herdr.get_agent(run.pane_id),
         {:ok, status} <- StatusLine.from_tokens(agent.tokens, run.id, run.checkpoint_at) do
      {:ok, status}
    else
      _unavailable -> :none
    end
  end

  @doc """
  Settles a completed turn whose hook tokens never arrived: the turn's last
  message, then the screen, then one status question.
  """
  @spec settle_unreported_turn(Run.t(), Agent.turn(), String.t() | nil) :: result()
  def settle_unreported_turn(run, turn, message) do
    with :error <- message |> StatusLine.find_last(run.id) |> tag("turn_message"),
         :error <- run |> screen_status() |> tag("screen") do
      ask_status(run, turn)
    else
      {:ok, status, source} -> apply_status(run, turn, status, source)
    end
  end

  defp tag({:ok, status}, source), do: {:ok, status, source}
  defp tag(:error, _source), do: :error

  defp screen_status(run) do
    case Herdr.read_agent(run.pane_id, @screen_lines) do
      {:ok, text} -> StatusLine.find_last(text, run.id)
      {:error, _reason} -> :error
    end
  end

  @spec apply_status(Run.t(), Agent.turn(), StatusLine.t(), String.t()) :: result()
  def apply_status(run, turn, %StatusLine{} = status, source) do
    attrs =
      case status.status do
        :completed -> %{state: :completed, finished_at: now(), wake_at: nil}
        :failed -> %{state: :failed, finished_at: now(), wake_at: nil}
        :blocked -> %{state: :blocked, wake_at: nil}
        :waiting -> %{state: :waiting, wake_at: status.until}
      end

    run
    |> transition(
      "turn_status",
      attrs
      |> Map.merge(turn_attrs(turn))
      |> Map.merge(%{checkpoint_at: now(), status_check_sent: false}),
      Map.merge(turn_data(turn), %{
        "status" => status.status,
        "until" => status.until,
        "source" => source
      })
    )
    |> auto_archive()
  end

  defp auto_archive({:ok, %Run{state: state} = run}) when state in [:completed, :failed] do
    with {:ok, %Run{job: %Job{auto_archive: true}}} <- Ash.load(run, :job),
         {:error, error} <- Run.archive(run) do
      Logger.warning("Could not archive run #{run.id}: #{Exception.message(error)}")
    end

    {:ok, run}
  end

  defp auto_archive(result), do: result

  defp ask_status(%{status_check_sent: true} = run, turn) do
    transition(
      run,
      "turn_without_status",
      Map.put(turn_attrs(turn), :state, :unknown),
      turn_data(turn)
    )
  end

  defp ask_status(run, turn) do
    with {:ok, run} <-
           transition(
             run,
             "status_check_sending",
             Map.merge(turn_attrs(turn), %{
               state: :unknown,
               status_check_sent: true,
               checkpoint_at: now()
             }),
             turn_data(turn)
           ) do
      text =
        "Fugate status check for run #{run.id}: reply only with the status line " <>
          "`fugate: <completed|waiting|blocked|failed> run=#{run.id}` " <>
          "(add ` until=<ISO-8601 datetime with offset>` for waiting) describing where this run stands."

      case Herdr.prompt_agent(run.pane_id, text, @prompt_timeout) do
        {:ok, delivery} ->
          transition(run, "status_check_sent", %{}, %{"delivery" => delivery})

        {:error, reason} ->
          transition(run, "status_check_failed", %{}, %{"error" => format_error(reason)})
      end
    end
  end

  @doc """
  Brings a placed run in line with Herdr's agent list after events may have
  been missed. Returns the run and the latest completed turn still to be
  processed, if any. A prompt whose delivery was interrupted is never re-sent:
  unless the agent shows it arrived, the run becomes blocked.
  """
  @spec reconcile(Run.t(), [Agent.t()]) ::
          {:ok, Run.t(), Agent.turn() | nil} | {:error, :not_active}
  def reconcile(%{state: :starting} = run, agents) do
    case find_agent(run, agents) do
      nil when is_nil(run.workspace_id) ->
        run
        |> transition("start_interrupted", %{state: :failed, finished_at: now()})
        |> without_missed_turn()

      nil ->
        run |> transition("start_interrupted", %{state: :lost}) |> without_missed_turn()

      agent ->
        with {:ok, run} <- adopt(run, agent) do
          resume(run, agent, "start_interrupted", "start_resumed")
        end
    end
  end

  def reconcile(run, agents) do
    case find_agent(run, agents) do
      nil when run.state == :lost ->
        {:ok, run, nil}

      nil ->
        run |> transition("agent_missing", %{state: :lost}) |> without_missed_turn()

      agent ->
        with {:ok, run} <- adopt(run, agent),
             {:ok, run} <- recover_lost(run) do
          case Map.fetch(@interrupted_deliveries, latest_delivery(run)) do
            {:ok, interrupted_event} -> resume(run, agent, interrupted_event, nil)
            :error -> {:ok, run, missed_turn(run, agent)}
          end
        end
    end
  end

  # The prompt arrived if the agent completed a turn since or is working on one.
  defp resume(run, agent, interrupted_event, resumed_event) do
    case {missed_turn(run, agent), agent.status} do
      {nil, status} when status != "working" ->
        run
        |> transition(interrupted_event, %{state: :blocked}, %{
          "reason" => "prompt delivery interrupted; not re-sent"
        })
        |> without_missed_turn()

      {missed, _status} ->
        with {:ok, run} <- mark_resumed(run, resumed_event), do: {:ok, run, missed}
    end
  end

  defp mark_resumed(run, nil = _event), do: {:ok, run}
  defp mark_resumed(run, event), do: transition(run, event, %{state: :running})

  defp latest_delivery(run) do
    case RunEvent.latest_of_kinds!(run.id, @delivery_events) do
      nil -> nil
      event -> event.kind
    end
  end

  defp recover_lost(%{state: :lost} = run), do: transition(run, "agent_found", %{state: :running})
  defp recover_lost(run), do: {:ok, run}

  defp missed_turn(run, agent) do
    if new_turn?(run, agent.completed_turn), do: agent.completed_turn
  end

  defp without_missed_turn({:ok, run}), do: {:ok, run, nil}
  defp without_missed_turn(not_active), do: not_active

  defp find_agent(run, agents) do
    Enum.find(agents, &(&1.pane_id == run.pane_id and &1.name == run.agent_name)) ||
      Enum.find(agents, &(run.agent_name != nil and &1.name == run.agent_name)) ||
      Enum.find(agents, &(run.terminal_id != nil and &1.terminal_id == run.terminal_id))
  end

  defp adopt(run, agent) do
    identity = Map.put(agent_identity(agent), :pane_id, agent.pane_id)

    if Enum.all?(identity, fn {key, value} -> Map.get(run, key) == value end) do
      {:ok, run}
    else
      transition(run, "agent_moved", identity, %{"pane_id" => agent.pane_id})
    end
  end

  defp agent_identity(agent), do: %{terminal_id: agent.terminal_id, agent_session: agent.session}

  defp turn_attrs({epoch, turn}), do: %{turn_epoch: epoch, last_turn: turn}
  defp turn_data({epoch, turn}), do: %{"turn" => turn, "turn_epoch" => epoch}

  defp preamble(run) do
    """
    You are running unattended as Fugate run #{run.id}. Work on the task below in this \
    repository, following the repository's own instructions.

    End EVERY turn with a final line of exactly this form:
    fugate: <status> run=#{run.id}[ until=<ISO-8601 datetime with offset>]
    where <status> is one of:
    - completed: the task is done.
    - waiting: the task must continue later; add until=<when>. You will be prompted to \
    continue at that time in this same session.
    - blocked: human intervention is needed before you can continue.
    - failed: the task cannot be done.

    Task:
    """
  end

  # A run finished through the API meanwhile (abandoned) is no longer driven.
  defp transition(run, event, attrs, data \\ %{}) do
    case Run.transition(run, event, Map.put(attrs, :event_data, data)) do
      {:ok, run} ->
        {:ok, run}

      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Changes.StaleRecord{}]}} ->
        {:error, :not_active}

      {:error, error} ->
        raise error
    end
  end

  defp format_error(%{"code" => code} = error),
    do: %{"code" => code, "message" => error["message"]}

  defp format_error({:unexpected_response, method}),
    do: %{"code" => "unexpected_response", "message" => method}

  defp format_error(reason), do: %{"code" => "transport", "message" => inspect(reason)}

  defp now, do: DateTime.utc_now()
end
