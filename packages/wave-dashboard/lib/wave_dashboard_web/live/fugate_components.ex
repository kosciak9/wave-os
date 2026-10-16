defmodule WaveDashboardWeb.FugateComponents do
  @moduledoc false
  use WaveDashboardWeb, :html

  import WaveDashboardWeb.Layouts, only: [wave_logo: 1, herdr_logo: 1]
  import WaveDashboardWeb.Icons, only: [icon: 1]

  alias WaveDashboard.Clock
  alias WaveDashboard.Fugate.{Client, Snapshot}
  alias WaveDashboard.Fugate.Client.{Agent, Run}

  attr :title, :string, required: true

  attr :crumbs, :list,
    default: [],
    doc: "`{label, path}` pairs between the home page and this one"

  slot :actions

  def page_header(assigns) do
    ~H"""
    <header class="topbar">
      <nav class="crumbs" aria-label="Breadcrumb">
        <.link navigate={~p"/"} class="brand"><.wave_logo /> ahri.wave</.link>
        <span aria-hidden="true">/</span>
        <.herdr_logo />
        <%= for {label, path} <- @crumbs do %>
          <.link navigate={path}>{label}</.link>
          <span aria-hidden="true">/</span>
        <% end %>
        <h1 class="page-title">{@title}</h1>
      </nav>
      <div :if={@actions != []} class="page-actions">{render_slot(@actions)}</div>
    </header>
    """
  end

  attr :flash, :map, required: true

  def flash(assigns) do
    ~H"""
    <p :if={message = Phoenix.Flash.get(@flash, :error)} class="banner banner-error" role="alert">
      {message}
    </p>
    <p :if={message = Phoenix.Flash.get(@flash, :info)} class="banner" role="status">
      {message}
    </p>
    """
  end

  @doc "Explains a snapshot that is not current, so stale data is never mistaken for live data."
  attr :snapshot, Snapshot, required: true

  def connection(%{snapshot: %Snapshot{status: :ok}} = assigns), do: ~H""

  def connection(%{snapshot: %Snapshot{status: :not_configured}} = assigns) do
    ~H"""
    <p class="banner">
      Fugate is not configured. Set <code>FUGATE_URL</code> for the dashboard service.
    </p>
    """
  end

  def connection(%{snapshot: %Snapshot{status: :loading}} = assigns) do
    ~H"""
    <p class="banner">Loading…</p>
    """
  end

  def connection(%{snapshot: %Snapshot{status: {:error, reason}}} = assigns) do
    assigns = assign(assigns, :reason, Client.describe(reason))

    ~H"""
    <p class="banner banner-error" role="alert">
      {@reason}.<span :if={@snapshot.jobs != []}> Showing the last known state.</span>
    </p>
    """
  end

  @doc "The scheduler's headline numbers: what runs, what is stuck, what failed, what comes next."
  attr :snapshot, Snapshot, required: true
  attr :now, DateTime, required: true

  def stats(assigns) do
    since = DateTime.add(assigns.now, -1, :day)

    assigns =
      assign(assigns,
        working:
          assigns.snapshot.agents &&
            Enum.count(assigns.snapshot.agents, &(&1.status == "working")),
        stuck: needs_attention(assigns.snapshot),
        failed:
          Enum.count(
            assigns.snapshot.finished_runs,
            &(&1.state == "failed" and &1.finished_at != nil and
                DateTime.after?(&1.finished_at, since))
          ),
        next: next_job(assigns.snapshot.jobs)
      )

    ~H"""
    <dl class="stats">
      <div class={["stat", @working && @working > 0 && "stat-running"]}>
        <dt>Working</dt>
        <dd>{@working || "—"}</dd>
      </div>
      <div class={["stat", @stuck > 0 && "stat-warning"]}>
        <dt>Needs attention</dt>
        <dd>{@stuck}</dd>
      </div>
      <div class={["stat", @failed > 0 && "stat-error"]}>
        <dt>Failed in 24h</dt>
        <dd>{@failed}</dd>
      </div>
      <div class="stat">
        <dt>Next run</dt>
        <dd :if={@next} class="stat-text">
          <.time at={@next.next_run_at} now={@now} />
          <span class="stat-detail">{@next.name}</span>
        </dd>
        <dd :if={!@next} class="stat-text muted">none scheduled</dd>
      </div>
    </dl>
    """
  end

  # Herdr's blocked agents, plus stuck Fugate runs whose pane is not already among them.
  defp needs_attention(snapshot) do
    blocked = Enum.filter(snapshot.agents || [], &Agent.needs_attention?/1)

    stuck_runs =
      Enum.count(snapshot.active_runs, fn run ->
        Run.needs_attention?(run) and
          not Enum.any?(blocked, &same_pane?(&1, run))
      end)

    length(blocked) + stuck_runs
  end

  # Herdr prefixes federated pane ids, so a run's pane id is the tail of the agent's.
  defp same_pane?(agent, run),
    do:
      run.pane_id != nil and agent.machine == run.host and
        String.ends_with?(agent.id, run.pane_id)

  defp next_job(jobs) do
    jobs
    |> Enum.filter(&(&1.enabled and &1.next_run_at != nil))
    |> Enum.min_by(& &1.next_run_at, DateTime, fn -> nil end)
  end

  @doc """
  Herdr's agents, those waiting for a person first. Agents a Fugate run drives carry
  Fugate's mark and link to the run. `limit` caps the list and counts the rest.
  """
  attr :agents, :list, required: true, doc: "nil while Herdr's directory cannot be read"
  attr :now, DateTime, required: true
  attr :limit, :integer, default: nil

  def agents(assigns) do
    agents = by_status(assigns.agents || [])
    shown = if assigns.limit, do: Enum.take(agents, assigns.limit), else: agents
    assigns = assign(assigns, shown: shown, hidden: length(agents) - length(shown))

    ~H"""
    <p :if={@agents == nil} class="muted">Herdr's agents are unavailable.</p>
    <p :if={@agents == []} class="muted">No agents in Herdr.</p>
    <ul :if={@shown != []} class="rows">
      <li :for={agent <- @shown}>
        <.link
          :if={agent.run_id}
          navigate={~p"/herdr/runs/#{agent.run_id}"}
          class={["row", agent.status == "idle" && "row-dim"]}
        >
          <.agent agent={agent} now={@now} />
        </.link>
        <div :if={!agent.run_id} class={["row", agent.status == "idle" && "row-dim"]}>
          <.agent agent={agent} now={@now} />
        </div>
      </li>
    </ul>
    <p :if={@hidden > 0} class="muted">and {@hidden} more</p>
    """
  end

  attr :agent, Agent, required: true
  attr :now, DateTime, required: true

  defp agent(assigns) do
    ~H"""
    <span
      class={["agent-origin", @agent.run_id && "agent-origin-fugate"]}
      title={if @agent.run_id, do: "Started by Fugate", else: "Started manually"}
    >
      <.icon name={if @agent.run_id, do: "wristwatch", else: "spock-hand-gesture"} />
      <span class="visually-hidden">
        {if @agent.run_id, do: "Started by Fugate", else: "Started manually"}
      </span>
    </span>
    <.state_badge state={@agent.status} />
    <span class="row-title" title={@agent.cwd}>{agent_title(@agent)}</span>
    <span class="row-meta sep">
      <span>{@agent.kind}</span>
      <span>{@agent.machine}</span>
      <.time at={@agent.status_since} now={@now} />
    </span>
    """
  end

  @status_order %{"blocked" => 0, "working" => 1, "done" => 2, "unknown" => 3, "idle" => 4}

  # Those waiting for a person first, then busy, then quiet; the latest change first within each.
  defp by_status(agents) do
    agents
    |> Enum.sort_by(&(&1.status_since || DateTime.from_unix!(0)), {:desc, DateTime})
    |> Enum.sort_by(&Map.get(@status_order, &1.status, 3))
  end

  defp agent_title(%{title: title}) when is_binary(title) and title != "", do: title
  defp agent_title(%{cwd: cwd}) when is_binary(cwd), do: Path.basename(cwd)
  defp agent_title(agent), do: agent.kind

  @doc "Active runs with the stuck ones first, then the newest."
  def by_urgency(runs), do: Enum.sort_by(runs, &(not Run.needs_attention?(&1)))

  attr :state, :string, required: true

  def state_badge(assigns) do
    ~H"""
    <span class={["state-badge", "state-#{state_class(@state)}"]}>{@state}</span>
    """
  end

  # Unknown states from a newer Fugate fall back to the neutral style.
  defp state_class(state)
       when state in ~w(queued starting running waiting blocked unknown lost completed failed abandoned
                        working idle done),
       do: state

  defp state_class(_state), do: "other"

  @doc "A moment shown relative to `now`, with the local date and time on hover."
  attr :at, DateTime, default: nil
  attr :now, DateTime, required: true

  def time(%{at: nil} = assigns), do: ~H'<span class="muted">—</span>'

  def time(assigns) do
    ~H"""
    <time datetime={DateTime.to_iso8601(@at)} title={Clock.format(@at)}>{Clock.relative(@at, @now)}</time>
    """
  end

  def job_name(jobs, job_id) do
    case Enum.find(jobs, &(&1.id == job_id)) do
      nil -> "deleted job"
      job -> job.name
    end
  end
end
