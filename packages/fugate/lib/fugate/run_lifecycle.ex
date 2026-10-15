defmodule Fugate.RunLifecycle do
  @moduledoc """
  Drives a run's agent through Herdr. Every step is persisted (with its run
  event) before the next Herdr call, so after a crash reconciliation can tell
  what was done, and a prompt is never sent twice.
  """

  alias Fugate.{Herdr, StatusLine}
  alias Fugate.Scheduling.Run

  # agent.start waits up to 30 s (Herdr default) for the harness to become ready.
  @start_timeout 45_000
  @prompt_timeout 30_000
  @screen_lines 80

  @spec start(Run.t(), map(), Fugate.Config.Host.t()) :: Run.t()
  def start(run, job, host) do
    agent_name = "fugate-" <> (run.id |> String.replace("-", "") |> binary_part(0, 8))

    run =
      transition!(run, "starting", %{state: :starting, host: host.name, agent_name: agent_name})

    case launch(run, job, host) do
      {:ok, run} ->
        run

      {:error, step, run, reason} ->
        transition!(run, "start_failed", %{state: :failed, finished_at: now()}, %{
          "step" => step,
          "error" => format_error(reason)
        })
    end
  end

  defp launch(run, job, host) do
    workspace =
      put_machine(%{cwd: job.repo_path, label: "fugate: #{job.name}", focus: false}, host)

    with {:ok, created} <-
           step(run, "workspace.create", Herdr.request("workspace.create", workspace)),
         run =
           transition!(run, "workspace_created", %{
             workspace_id: created["workspace"]["workspace_id"],
             pane_id: created["root_pane"]["pane_id"]
           }),
         start = %{name: run.agent_name, kind: Atom.to_string(job.harness), pane_id: run.pane_id},
         {:ok, _} <-
           step(run, "agent.start", Herdr.request("agent.start", start, @start_timeout)),
         {:ok, %{"agent" => agent}} <-
           step(run, "agent.get", Herdr.request("agent.get", %{target: run.pane_id})),
         run =
           transition!(
             run,
             "agent_started",
             Map.merge(agent_identity(agent), %{
               last_turn: completed_turn(agent),
               checkpoint_at: now()
             })
           ),
         prompt = %{target: run.pane_id, text: preamble(run) <> job.prompt},
         {:ok, prompted} <-
           step(run, "agent.prompt", Herdr.request("agent.prompt", prompt, @prompt_timeout)) do
      {:ok,
       transition!(run, "prompt_sent", %{state: :running}, %{"delivery" => prompted["delivery"]})}
    end
  end

  defp put_machine(params, %{herdr_alias: nil}), do: params
  defp put_machine(params, %{herdr_alias: alias}), do: Map.put(params, :machine, alias)

  defp step(_run, _name, {:ok, result}), do: {:ok, result}
  defp step(run, name, {:error, reason}), do: {:error, name, run, reason}

  @doc "Sends the scheduled continuation of a waiting run."
  @spec continue(Run.t()) :: Run.t()
  def continue(run) do
    wake_at = run.wake_at

    run =
      transition!(
        run,
        "continuation_sending",
        %{state: :running, wake_at: nil, checkpoint_at: now()},
        %{"wake_at" => wake_at}
      )

    text =
      "Fugate: continue run #{run.id} now (scheduled continuation at #{DateTime.to_iso8601(wake_at)}). " <>
        "End with the status line."

    case Herdr.request("agent.prompt", %{target: run.pane_id, text: text}, @prompt_timeout) do
      {:ok, prompted} ->
        transition!(run, "continuation_sent", %{}, %{"delivery" => prompted["delivery"]})

      {:error, reason} ->
        transition!(run, "continuation_failed", %{state: :blocked}, %{
          "error" => format_error(reason)
        })
    end
  end

  @doc "The status the hook reported for the latest turn, if it has landed yet."
  @spec reported_status(Run.t()) :: {:ok, StatusLine.t()} | :none
  def reported_status(run) do
    with {:ok, %{"agent" => agent}} <- Herdr.request("agent.get", %{target: run.pane_id}),
         {:ok, status} <-
           StatusLine.from_tokens(agent["tokens"] || %{}, run.id, run.checkpoint_at) do
      {:ok, status}
    else
      _ -> :none
    end
  end

  @doc """
  Settles a completed turn whose hook tokens never arrived: the turn's last
  message, then the screen, then one status question.
  """
  @spec settle_unreported_turn(Run.t(), non_neg_integer(), String.t() | nil) :: Run.t()
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
    read = %{target: run.pane_id, source: "recent_unwrapped", lines: @screen_lines}

    case Herdr.request("agent.read", read) do
      {:ok, %{"read" => %{"text" => text}}} -> StatusLine.find_last(text, run.id)
      {:error, _} -> :error
    end
  end

  @spec apply_status(Run.t(), non_neg_integer(), StatusLine.t(), String.t()) :: Run.t()
  def apply_status(run, turn, %StatusLine{} = status, source) do
    attrs =
      case status.status do
        :completed -> %{state: :completed, finished_at: now(), wake_at: nil}
        :failed -> %{state: :failed, finished_at: now(), wake_at: nil}
        :blocked -> %{state: :blocked, wake_at: nil}
        :waiting -> %{state: :waiting, wake_at: status.until}
      end

    transition!(
      run,
      "turn_status",
      Map.merge(attrs, %{last_turn: turn, checkpoint_at: now(), status_check_sent: false}),
      %{"turn" => turn, "status" => status.status, "until" => status.until, "source" => source}
    )
  end

  defp ask_status(%{status_check_sent: true} = run, turn) do
    transition!(run, "turn_without_status", %{state: :unknown, last_turn: turn}, %{
      "turn" => turn
    })
  end

  defp ask_status(run, turn) do
    run =
      transition!(
        run,
        "status_check_sending",
        %{state: :unknown, last_turn: turn, status_check_sent: true, checkpoint_at: now()},
        %{"turn" => turn}
      )

    text =
      "Fugate status check for run #{run.id}: reply only with the status line " <>
        "`fugate: <completed|waiting|blocked|failed> run=#{run.id}` " <>
        "(add ` until=<ISO-8601 datetime with offset>` for waiting) describing where this run stands."

    case Herdr.request("agent.prompt", %{target: run.pane_id, text: text}, @prompt_timeout) do
      {:ok, prompted} ->
        transition!(run, "status_check_sent", %{}, %{"delivery" => prompted["delivery"]})

      {:error, reason} ->
        transition!(run, "status_check_failed", %{}, %{"error" => format_error(reason)})
    end
  end

  @doc """
  Brings a placed run in line with Herdr's agent list after events may have
  been missed. Returns the run and the latest completed turn still to be
  processed, if any.
  """
  @spec reconcile(Run.t(), [map()]) :: {Run.t(), non_neg_integer() | nil}
  def reconcile(%{state: :starting} = run, agents) do
    case find_agent(run, agents) do
      nil when is_nil(run.workspace_id) ->
        {transition!(run, "start_interrupted", %{state: :failed, finished_at: now()}), nil}

      nil ->
        {transition!(run, "start_interrupted", %{state: :lost}), nil}

      agent ->
        run = adopt(run, agent)
        last_turn = run.last_turn || 0
        turn = completed_turn(agent)

        if turn > last_turn or agent["agent_status"] == "working" do
          run = transition!(run, "start_resumed", %{state: :running, last_turn: last_turn})
          {run, missed(turn, last_turn)}
        else
          {transition!(run, "start_interrupted", %{state: :blocked}, %{
             "reason" => "start interrupted; prompt delivery unknown"
           }), nil}
        end
    end
  end

  def reconcile(run, agents) do
    case find_agent(run, agents) do
      nil when run.state == :lost ->
        {run, nil}

      nil ->
        {transition!(run, "agent_missing", %{state: :lost}), nil}

      agent ->
        run = adopt(run, agent)

        run =
          if run.state == :lost,
            do: transition!(run, "agent_found", %{state: :running}),
            else: run

        {run, missed(completed_turn(agent), run.last_turn || 0)}
    end
  end

  defp missed(turn, last_turn) when turn > last_turn, do: turn
  defp missed(_turn, _last_turn), do: nil

  defp find_agent(run, agents) do
    Enum.find(agents, &(&1["pane_id"] == run.pane_id and &1["name"] == run.agent_name)) ||
      Enum.find(agents, &(run.agent_name != nil and &1["name"] == run.agent_name)) ||
      Enum.find(agents, &(run.terminal_id != nil and &1["terminal_id"] == run.terminal_id))
  end

  defp adopt(run, agent) do
    identity = Map.put(agent_identity(agent), :pane_id, agent["pane_id"])

    if Enum.all?(identity, fn {key, value} -> Map.get(run, key) == value end) do
      run
    else
      transition!(run, "agent_moved", identity, %{"pane_id" => agent["pane_id"]})
    end
  end

  defp agent_identity(agent) do
    %{
      terminal_id: agent["terminal_id"],
      agent_session: get_in(agent, ["agent_session", "value"])
    }
  end

  defp completed_turn(agent), do: get_in(agent, ["last_completed_turn", "turn"]) || 0

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

  defp transition!(run, event, attrs, data \\ %{}) do
    Run.transition!(run, event, Map.put(attrs, :event_data, data))
  end

  defp format_error(%{"code" => code} = error),
    do: %{"code" => code, "message" => error["message"]}

  defp format_error(reason), do: %{"code" => "transport", "message" => inspect(reason)}

  defp now, do: DateTime.utc_now()
end
