defmodule WaveDashboardWeb.FugateComponents do
  @moduledoc false
  use WaveDashboardWeb, :html

  import WaveDashboardWeb.Layouts, only: [wave_logo: 1]

  alias WaveDashboard.Clock
  alias WaveDashboard.Fugate.{Client, Snapshot}
  alias WaveDashboard.Fugate.Client.Run

  attr :title, :string, required: true
  attr :crumbs, :list, required: true, doc: "`{label, path}` pairs leading to this page"
  slot :actions

  def page_header(assigns) do
    ~H"""
    <header class="topbar">
      <.link navigate={~p"/"} class="brand" aria-label="ahri.wave">
        <.wave_logo />
      </.link>
      <nav class="crumbs" aria-label="Breadcrumb">
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
        running: length(assigns.snapshot.active_runs),
        stuck: Enum.count(assigns.snapshot.active_runs, &Run.needs_attention?/1),
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
      <div class={["stat", @running > 0 && "stat-running"]}>
        <dt>Running</dt>
        <dd>
          {@running}<span :if={@snapshot.max_concurrent} class="stat-of">/{@snapshot.max_concurrent}</span>
        </dd>
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

  defp next_job(jobs) do
    jobs
    |> Enum.filter(&(&1.enabled and &1.next_run_at != nil))
    |> Enum.min_by(& &1.next_run_at, DateTime, fn -> nil end)
  end

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
       when state in ~w(queued starting running waiting blocked unknown lost completed failed abandoned),
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
