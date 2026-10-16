defmodule WaveDashboardWeb.FugateRunLive do
  @moduledoc "One Fugate run and its events, reloaded whenever the polled run changes."
  use WaveDashboardWeb, :live_view

  import WaveDashboardWeb.FugateComponents

  alias WaveDashboard.{Clock, Fugate}
  alias WaveDashboard.Fugate.Client
  alias WaveDashboard.Fugate.Client.Run

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    socket =
      assign(socket,
        id: id,
        now: DateTime.utc_now(),
        snapshot: Fugate.snapshot(),
        run: nil,
        events: [],
        error: nil,
        abandoning?: false,
        archiving?: false,
        page_title: "Run · Herdr"
      )

    if connected?(socket) do
      Fugate.subscribe()
      Clock.tick_next_minute(:tick)
      {:ok, load(socket)}
    else
      {:ok, socket}
    end
  end

  defp load(socket) do
    id = socket.assigns.id
    start_async(socket, :load, fn -> Client.run_with_events(id) end)
  end

  @impl true
  def handle_async(:load, {:ok, {:ok, run, events}}, socket),
    do: {:noreply, assign(socket, run: run, events: events, error: nil)}

  def handle_async(:load, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, error: Client.describe(reason))}

  def handle_async(:load, {:exit, reason}, socket),
    do: {:noreply, assign(socket, error: Client.describe(reason))}

  def handle_async(:abandon, result, socket) do
    socket = socket |> assign(abandoning?: false) |> clear_flash()

    case result do
      {:ok, {:ok, run}} ->
        Fugate.refresh()
        {:noreply, socket |> assign(run: run) |> put_flash(:info, "Run abandoned") |> load()}

      {:ok, {:error, reason}} ->
        {:noreply, put_flash(socket, :error, Client.describe(reason))}

      {:exit, reason} ->
        {:noreply, put_flash(socket, :error, Client.describe(reason))}
    end
  end

  def handle_async(:archive, result, socket) do
    socket = socket |> assign(archiving?: false) |> clear_flash()

    case result do
      {:ok, {:ok, run}} ->
        Fugate.refresh()
        {:noreply, socket |> assign(run: run) |> put_flash(:info, "Session archived") |> load()}

      {:ok, {:error, reason}} ->
        {:noreply, put_flash(socket, :error, Client.describe(reason))}

      {:exit, reason} ->
        {:noreply, put_flash(socket, :error, Client.describe(reason))}
    end
  end

  @impl true
  def handle_info(:tick, socket) do
    Clock.tick_next_minute(:tick)
    {:noreply, assign(socket, now: DateTime.utc_now())}
  end

  def handle_info({:fugate, snapshot}, socket) do
    socket = assign(socket, snapshot: snapshot)

    case Enum.find(snapshot.active_runs ++ snapshot.finished_runs, &(&1.id == socket.assigns.id)) do
      nil -> {:noreply, socket}
      run when run == socket.assigns.run -> {:noreply, socket}
      _changed -> {:noreply, load(socket)}
    end
  end

  @impl true
  def handle_event("abandon", _params, %{assigns: %{abandoning?: true}} = socket),
    do: {:noreply, socket}

  def handle_event("abandon", _params, socket) do
    id = socket.assigns.id

    {:noreply,
     socket |> assign(abandoning?: true) |> start_async(:abandon, fn -> Client.abandon(id) end)}
  end

  def handle_event("archive", _params, %{assigns: %{archiving?: true}} = socket),
    do: {:noreply, socket}

  def handle_event("archive", _params, socket) do
    id = socket.assigns.id

    {:noreply,
     socket
     |> assign(archiving?: true)
     |> start_async(:archive, fn -> Client.archive_run(id) end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page">
      <.page_header title="Run" crumbs={[{"Herdr", ~p"/herdr"}]}>
        <:actions :if={@run && Run.active?(@run)}>
          <button
            type="button"
            class="button button-danger"
            phx-click="abandon"
            disabled={@abandoning?}
            data-confirm="Abandon this run? The agent itself is left running."
          >
            {if @abandoning?, do: "Abandoning…", else: "Abandon"}
          </button>
        </:actions>
        <:actions :if={@run && Run.archivable?(@run)}>
          <button
            type="button"
            class="button button-quiet"
            phx-click="archive"
            disabled={@archiving?}
            data-confirm="Archive this run? Its Herdr agent and workspace are closed."
          >
            {if @archiving?, do: "Archiving…", else: "Archive"}
          </button>
        </:actions>
      </.page_header>

      <.flash flash={@flash} />
      <.connection snapshot={@snapshot} />
      <p :if={@error} class="banner banner-error" role="alert">{@error}</p>
      <p :if={!@run and !@error} class="muted">Loading…</p>

      <div :if={@run} class="columns">
        <main class="column-main">
          <section class="card">
            <div class="card-header">
              <h2 class="card-title">{job_name(@snapshot.jobs, @run.job_id)}</h2>
              <.state_badge state={@run.state} />
            </div>
            <h3 class="group-title">Events</h3>
            <p :if={@events == []} class="muted">No events.</p>
            <ol :if={@events != []} class="timeline">
              <li :for={event <- @events}>
                <div class="timeline-head">
                  <span class="event-kind">{event.kind}</span>
                  <span class="row-meta">{Clock.format(event.inserted_at)}</span>
                </div>
                <pre :if={event.data != %{}} class="event-data">{JSON.encode!(event.data)}</pre>
              </li>
            </ol>
          </section>
        </main>

        <aside class="column-side">
          <section class="card">
            <h2 class="card-title">Details</h2>
            <dl class="facts facts-list">
              <div>
                <dt>Host</dt><dd>{@run.host || "—"}</dd>
              </div>
              <div>
                <dt>Trigger</dt><dd>{@run.trigger || "—"}</dd>
              </div>
              <div>
                <dt>Created</dt><dd><.time at={@run.inserted_at} now={@now} /></dd>
              </div>
              <div>
                <dt>Checkpoint</dt><dd><.time at={@run.checkpoint_at} now={@now} /></dd>
              </div>
              <div>
                <dt>Wakes</dt><dd><.time at={@run.wake_at} now={@now} /></dd>
              </div>
              <div>
                <dt>Finished</dt><dd><.time at={@run.finished_at} now={@now} /></dd>
              </div>
              <div :if={@run.archived_at}>
                <dt>Archived</dt><dd><.time at={@run.archived_at} now={@now} /></dd>
              </div>
              <div>
                <dt>Last turn</dt><dd>{@run.last_turn || "—"}</dd>
              </div>
              <div>
                <dt>Agent</dt><dd>{@run.agent_name || "—"}</dd>
              </div>
              <div>
                <dt>Workspace</dt><dd class="mono">{@run.workspace_id || "—"}</dd>
              </div>
              <div>
                <dt>Pane</dt><dd class="mono">{@run.pane_id || "—"}</dd>
              </div>
              <div>
                <dt>Run</dt><dd class="mono">{@run.id}</dd>
              </div>
            </dl>
          </section>
        </aside>
      </div>
    </div>
    """
  end
end
