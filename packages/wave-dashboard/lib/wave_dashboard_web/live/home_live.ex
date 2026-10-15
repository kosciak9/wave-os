defmodule WaveDashboardWeb.HomeLive do
  use WaveDashboardWeb, :live_view

  import WaveDashboardWeb.FugateComponents,
    only: [stats: 1, state_badge: 1, time: 1, job_name: 2, by_urgency: 1]

  import WaveDashboardWeb.Layouts, only: [wave_logo: 1]

  alias WaveDashboard.{Apps, Clock, Deadline, Fugate, Tailnet}

  @shown_runs 5

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Apps.subscribe()
      Tailnet.subscribe()
      Deadline.subscribe()
      Fugate.subscribe()
      Clock.tick_next_minute(:tick)
    end

    {:ok,
     socket
     |> assign(apps: Apps.list(), hosts: Tailnet.hosts(), fugate: Fugate.snapshot())
     |> assign(editing?: false, deadline_error: nil, draft: nil)
     |> assign_now()
     |> assign_deadline()}
  end

  @impl true
  def handle_info({:apps, apps}, socket), do: {:noreply, assign(socket, apps: apps)}
  def handle_info({:hosts, hosts}, socket), do: {:noreply, assign(socket, hosts: hosts)}
  def handle_info({:fugate, snapshot}, socket), do: {:noreply, assign(socket, fugate: snapshot)}
  def handle_info(:deadline_changed, socket), do: {:noreply, assign_deadline(socket)}

  def handle_info(:tick, socket) do
    Clock.tick_next_minute(:tick)
    {:noreply, assign_now(socket)}
  end

  @impl true
  def handle_event("edit_deadline", _params, socket),
    do: {:noreply, assign(socket, editing?: true)}

  def handle_event("cancel_deadline", _params, socket),
    do: {:noreply, assign(socket, editing?: false, deadline_error: nil, draft: nil)}

  def handle_event("save_deadline", %{"label" => label, "end_date" => end_date}, socket) do
    case Deadline.save(label, end_date) do
      {:ok, _deadline} ->
        {:noreply, assign(socket, editing?: false, deadline_error: nil, draft: nil)}

      {:error, message} ->
        {:noreply,
         assign(socket, deadline_error: message, draft: %{label: label, end_date: end_date})}
    end
  end

  def handle_event("reset_deadline", _params, socket) do
    case Deadline.reset() do
      :ok ->
        {:noreply, assign(socket, editing?: false, deadline_error: nil, draft: nil)}

      {:error, _reason} ->
        {:noreply, assign(socket, deadline_error: "Could not reset the deadline")}
    end
  end

  defp assign_deadline(socket), do: assign(socket, deadline: Deadline.load())

  defp assign_now(socket) do
    now = DateTime.utc_now()
    assign(socket, now: now, local_now: Clock.to_local(now))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page">
      <header class="topbar">
        <span class="brand"><.wave_logo /> ahri.wave</span>
        <form action="https://duckduckgo.com/" method="get" class="search-form">
          <label class="visually-hidden" for="search">Search</label>
          <input
            id="search"
            type="search"
            name="q"
            class="search-input"
            placeholder="Search DuckDuckGo"
            autocomplete="off"
            autofocus
          />
        </form>
        <.theme_toggle />
      </header>

      <div class="columns">
        <main class="column-main">
          <.deadline_form
            :if={@editing? or not is_struct(@deadline, Deadline)}
            deadline={@deadline}
            draft={@draft}
            error={@deadline_error}
            editing?={@editing?}
          />
          <.deadline
            :if={not @editing? and is_struct(@deadline, Deadline)}
            deadline={@deadline}
            now={@local_now}
          />
          <.agents snapshot={@fugate} now={@now} />
        </main>

        <aside class="column-side">
          <.apps apps={@apps} />
          <.hosts hosts={@hosts} now={@now} />
        </aside>
      </div>
    </div>
    """
  end

  defp theme_toggle(assigns) do
    ~H"""
    <button type="button" id="theme-toggle" class="icon-button" aria-label="Toggle theme">
      <svg class="theme-icon theme-icon-light" viewBox="0 0 24 24" fill="none" stroke-width="1.5">
        <circle cx="12" cy="12" r="5" />
        <path d="M12 1v2M12 21v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M1 12h2M21 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42" />
      </svg>
      <svg class="theme-icon theme-icon-dark" viewBox="0 0 24 24" fill="none" stroke-width="1.5">
        <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79Z" />
      </svg>
    </button>
    """
  end

  attr :deadline, :any, required: true
  attr :draft, :map, required: true
  attr :error, :string, required: true
  attr :editing?, :boolean, required: true

  defp deadline_form(assigns) do
    assigns =
      assign(assigns,
        values:
          assigns.draft ||
            case assigns.deadline do
              %Deadline{} = deadline ->
                %{label: deadline.label, end_date: Date.to_iso8601(deadline.end_date)}

              _none ->
                %{label: "", end_date: ""}
            end
      )

    ~H"""
    <section class="card">
      <h2 class="card-title">Deadline</h2>
      <p :if={@deadline == :corrupt} class="banner banner-error" role="alert">
        Saved deadline data is corrupt. Create a new deadline or reset it.
      </p>
      <p :if={@error} class="form-error" role="alert">{@error}</p>
      <form phx-submit="save_deadline" class="deadline-form">
        <label class="visually-hidden" for="deadline-label">Label</label>
        <input
          id="deadline-label"
          type="text"
          name="label"
          value={@values.label}
          placeholder="Label (e.g., Sprint 1)"
        />
        <label class="visually-hidden" for="deadline-end-date">End date</label>
        <input id="deadline-end-date" type="date" name="end_date" value={@values.end_date} />
        <button type="submit" class="button">Set deadline</button>
        <button :if={@editing?} type="button" class="button button-quiet" phx-click="cancel_deadline">
          Cancel
        </button>
        <button
          :if={@deadline == :corrupt or @editing?}
          type="button"
          class="button button-danger"
          phx-click="reset_deadline"
        >
          Clear
        </button>
      </form>
    </section>
    """
  end

  attr :deadline, Deadline, required: true
  attr :now, NaiveDateTime, required: true

  defp deadline(assigns) do
    today = NaiveDateTime.to_date(assigns.now)
    {total, elapsed, remaining} = Deadline.days(assigns.deadline, today)

    assigns =
      assign(assigns,
        today: today,
        total: total,
        elapsed: elapsed,
        remaining: remaining,
        expired?: Deadline.expired?(assigns.deadline, today),
        minutes_left: Deadline.minutes_left(assigns.deadline, assigns.now)
      )

    ~H"""
    <section class={["card", "deadline", @expired? && "deadline-expired"]}>
      <div class="card-header">
        <h2 class="card-title">
          <button type="button" class="link-button" title="Edit deadline" phx-click="edit_deadline">
            {@deadline.label}
          </button>
        </h2>
        <span class="card-detail">ends {Calendar.strftime(@deadline.end_date, "%a %d %b")}</span>
      </div>
      <div class="countdown">
        <span :if={!@expired?} class="countdown-value">
          <span>{div(@minutes_left, 60)}<small>h</small></span>
          <span>{@minutes_left |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}<small>m</small></span>
        </span>
        <span :if={@expired?} class="countdown-value">Passed</span>
        <span class="countdown-caption">
          <%= if @expired? do %>
            <button type="button" class="link-button" phx-click="edit_deadline">Set a new deadline</button>
          <% else %>
            <span class="sep">
              <span>{@remaining} {if @remaining == 1, do: "day", else: "days"} left</span>
              <span>day {@elapsed} of {@total}</span>
            </span>
          <% end %>
        </span>
      </div>
      <div class="deadline-grid" role="img" aria-label={"Day #{@elapsed} of #{@total}"}>
        <div :for={block <- Deadline.grid(@deadline, @today)} class="deadline-week">
          <div
            :for={{date, kind} <- block}
            class={["deadline-day", Atom.to_string(kind)]}
            title={Date.to_iso8601(date)}
          >
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :snapshot, :any, required: true
  attr :now, DateTime, required: true

  defp agents(assigns) do
    runs = by_urgency(assigns.snapshot.active_runs)

    assigns =
      assign(assigns,
        runs: Enum.take(runs, @shown_runs),
        hidden: max(0, length(runs) - @shown_runs)
      )

    ~H"""
    <section class="card">
      <div class="card-header">
        <h2 class="card-title">
          <img src={~p"/images/fugate-favicon.png"} alt="" class="avatar" /> Agents
        </h2>
        <.link navigate={~p"/fugate"} class="card-link">Open Fugate →</.link>
      </div>
      <%= case @snapshot.status do %>
        <% :not_configured -> %>
          <p class="muted">Fugate is not configured.</p>
        <% :loading -> %>
          <p class="muted">Loading…</p>
        <% status -> %>
          <p :if={status != :ok} class="banner banner-error" role="alert">
            Fugate unreachable. Showing the last known state.
          </p>
          <.stats snapshot={@snapshot} now={@now} />
          <ul :if={@runs != []} class="rows">
            <li :for={run <- @runs}>
              <.link navigate={~p"/fugate/runs/#{run.id}"} class="row">
                <.state_badge state={run.state} />
                <span class="row-title">{job_name(@snapshot.jobs, run.job_id)}</span>
                <span class="row-meta sep">
                  <span>{run.host || "unassigned"}</span>
                  <.time at={run.inserted_at} now={@now} />
                </span>
              </.link>
            </li>
          </ul>
          <p :if={@runs == []} class="muted">Nothing running.</p>
          <p :if={@hidden > 0} class="muted">and {@hidden} more in Fugate</p>
      <% end %>
    </section>
    """
  end

  attr :apps, :list, required: true

  defp apps(assigns) do
    ~H"""
    <section class="card">
      <h2 class="card-title">Apps</h2>
      <div :if={@apps == []} class="muted">
        <p>No apps registered.</p>
        <p>Register one with <code>wave dashboard add</code>.</p>
      </div>
      <div :for={{project, apps} <- Enum.group_by(@apps, & &1.project)} class="group">
        <h3 class="group-title">{project}</h3>
        <ul class="rows">
          <li :for={app <- apps}>
            <a href={Apps.url(app)} target="_blank" rel="noopener noreferrer" class="row">
              <span class={["status", Atom.to_string(app.status)]} title={status_title(app.status)}></span>
              <span class="row-title mono">{app.branch}</span>
              <span class="row-meta">{app.host}</span>
            </a>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  defp status_title(:up), do: "Responding"
  defp status_title(:down), do: "Not responding"
  defp status_title(:unknown), do: "Not checked yet"

  attr :hosts, :list, required: true
  attr :now, DateTime, required: true

  defp hosts(assigns) do
    ~H"""
    <section class="card">
      <div class="card-header">
        <h2 class="card-title">Hosts</h2>
        <span class="card-detail">{Enum.count(@hosts, & &1.online?)}/{length(@hosts)} online</span>
      </div>
      <ul class="rows">
        <li
          :for={host <- Enum.sort_by(@hosts, &(not &1.online?))}
          class={["row", not host.online? && "row-dim"]}
        >
          <span
            class={["status", if(host.online?, do: "up", else: "down")]}
            title={if host.online?, do: "Online", else: "Offline"}
          ></span>
          <span class="row-title mono">{host.name}</span>
          <span class="row-meta">
            <%= cond do %>
              <% host.online? -> %>
                {host.os}
              <% host.last_seen -> %>
                seen <.time at={host.last_seen} now={@now} />
              <% true -> %>
                offline
            <% end %>
          </span>
        </li>
      </ul>
    </section>
    """
  end
end
