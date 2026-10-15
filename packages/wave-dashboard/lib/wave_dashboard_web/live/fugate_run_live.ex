defmodule WaveDashboardWeb.FugateRunLive do
  @moduledoc "One Fugate run and its events, reloaded whenever the polled run changes."
  use WaveDashboardWeb, :live_view

  import WaveDashboardWeb.FugateComponents

  alias WaveDashboard.Fugate
  alias WaveDashboard.Fugate.Client

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    socket = assign(socket, id: id, snapshot: Fugate.snapshot(), run: nil, events: [], error: nil)

    if connected?(socket) do
      Fugate.subscribe()
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

  @impl true
  def handle_info({:fugate, snapshot}, socket) do
    socket = assign(socket, snapshot: snapshot)

    case Enum.find(snapshot.active_runs ++ snapshot.finished_runs, &(&1.id == socket.assigns.id)) do
      nil -> {:noreply, socket}
      run when run == socket.assigns.run -> {:noreply, socket}
      _changed -> {:noreply, load(socket)}
    end
  end

  @impl true
  def handle_event("abandon", _params, socket) do
    case Client.abandon(socket.assigns.id) do
      {:ok, run} ->
        Fugate.refresh()

        {:noreply,
         socket
         |> assign(run: run)
         |> clear_flash()
         |> put_flash(:info, "Run abandoned")
         |> load()}

      {:error, reason} ->
        {:noreply, socket |> clear_flash() |> put_flash(:error, Client.describe(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container fugate">
      <.page_header title="Run" back={~p"/fugate"} back_label="Fugate">
        <:actions :if={@run && active?(@run)}>
          <button
            type="button"
            class="button button-danger"
            phx-click="abandon"
            data-confirm="Abandon this run? The agent itself is left running."
          >
            Abandon
          </button>
        </:actions>
      </.page_header>

      <.flash flash={@flash} />
      <.connection snapshot={@snapshot} />
      <p :if={@error} class="error" role="alert">{@error}</p>

      <section :if={@run} class="project">
        <div class="project-header section-header">
          {job_name(@snapshot.jobs, @run.job_id)}
          <.state_badge state={@run.state} />
        </div>
        <dl class="run-facts run-details">
          <div>
            <dt>Run</dt><dd class="mono">{@run.id}</dd>
          </div>
          <div>
            <dt>Trigger</dt><dd>{@run.trigger || "—"}</dd>
          </div>
          <div>
            <dt>Host</dt><dd>{@run.host || "—"}</dd>
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
            <dt>Last turn</dt><dd>{@run.last_turn || "—"}</dd>
          </div>
          <div>
            <dt>Wakes</dt><dd>{format_time(@run.wake_at)}</dd>
          </div>
          <div>
            <dt>Checkpoint</dt><dd>{format_time(@run.checkpoint_at)}</dd>
          </div>
          <div>
            <dt>Created</dt><dd>{format_time(@run.inserted_at)}</dd>
          </div>
          <div>
            <dt>Finished</dt><dd>{format_time(@run.finished_at)}</dd>
          </div>
        </dl>
      </section>

      <section :if={@run} class="project">
        <div class="project-header">Events</div>
        <ol class="branch-list event-list">
          <li :for={event <- @events} class="branch-item event-item">
            <div class="run-line">
              <span class="run-job mono">{event.kind}</span>
              <span class="host-badge">{format_time(event.inserted_at)}</span>
            </div>
            <pre :if={event.data != %{}} class="event-data">{JSON.encode!(event.data)}</pre>
          </li>
          <li :if={@events == []} class="branch-item muted">No events.</li>
        </ol>
      </section>

      <p :if={!@run and !@error} class="notice">Loading…</p>
    </div>
    """
  end
end
