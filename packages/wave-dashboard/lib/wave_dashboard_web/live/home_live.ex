defmodule WaveDashboardWeb.HomeLive do
  use WaveDashboardWeb, :live_view

  alias WaveDashboard.{Apps, Deadline, Tailnet}

  @day_check_interval :timer.minutes(1)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Apps.subscribe()
      Tailnet.subscribe()
      Deadline.subscribe()
      :timer.send_interval(@day_check_interval, :day_check)
    end

    {:ok,
     socket
     |> assign(apps: Apps.list(), hosts: Tailnet.hosts(), today: Deadline.today())
     |> assign(editing?: false, deadline_error: nil, draft: nil)
     |> assign_deadline()}
  end

  @impl true
  def handle_info({:apps, apps}, socket), do: {:noreply, assign(socket, apps: apps)}
  def handle_info({:hosts, hosts}, socket), do: {:noreply, assign(socket, hosts: hosts)}
  def handle_info(:deadline_changed, socket), do: {:noreply, assign_deadline(socket)}
  def handle_info(:day_check, socket), do: {:noreply, assign(socket, today: Deadline.today())}

  @impl true
  def handle_event("edit_deadline", _params, socket),
    do: {:noreply, assign(socket, editing?: true)}

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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container">
      <header>
        <img src={~p"/images/logo.png"} alt="Wave" class="logo" />
      </header>

      <.countdown deadline={@deadline} today={@today} />

      <form action="https://duckduckgo.com/" method="get" class="search-form">
        <label class="visually-hidden" for="search">Search</label>
        <input
          id="search"
          type="text"
          name="q"
          class="search-input"
          placeholder="Search DuckDuckGo..."
          autocomplete="off"
          autofocus
        />
      </form>

      <section>
        <.deadline_form
          :if={@editing? or not is_struct(@deadline, Deadline)}
          deadline={@deadline}
          draft={@draft}
          error={@deadline_error}
        />
        <.deadline_progress
          :if={not @editing? and is_struct(@deadline, Deadline)}
          deadline={@deadline}
          today={@today}
        />
      </section>

      <main>
        <.apps apps={@apps} />
        <.hosts hosts={@hosts} />
      </main>

      <footer class="theme-toggle-footer">
        <button type="button" id="theme-toggle" class="theme-toggle" aria-label="Toggle theme">
          <svg class="theme-icon theme-icon-light" viewBox="0 0 24 24" fill="none" stroke-width="1.5">
            <circle cx="12" cy="12" r="5" />
            <path d="M12 1v2M12 21v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M1 12h2M21 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42" />
          </svg>
          <svg class="theme-icon theme-icon-dark" viewBox="0 0 24 24" fill="none" stroke-width="1.5">
            <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79Z" />
          </svg>
        </button>
      </footer>
    </div>
    """
  end

  attr :deadline, :any, required: true
  attr :today, Date, required: true

  defp countdown(%{deadline: %Deadline{}} = assigns) do
    ~H"""
    <%= if Deadline.expired?(@deadline, @today) do %>
      <div class="countdown expired">00:00:00:00</div>
      <div class="countdown-label">{@deadline.label}</div>
      <div class="countdown-reset">
        <button type="button" phx-click="reset_deadline">set a new deadline</button>
      </div>
    <% else %>
      <div
        id="countdown"
        class="countdown"
        phx-hook="Countdown"
        phx-update="ignore"
        data-end-date={Date.to_iso8601(@deadline.end_date)}
      >
      </div>
    <% end %>
    """
  end

  defp countdown(assigns), do: ~H""

  attr :deadline, :any, required: true
  attr :draft, :map, required: true
  attr :error, :string, required: true

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
    <div class="deadline">
      <p :if={@deadline == :corrupt} class="error" role="alert">
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
        <button type="submit">Set Deadline</button>
      </form>
      <button
        :if={@deadline == :corrupt}
        type="button"
        class="button-reset"
        phx-click="reset_deadline"
      >
        Reset deadline
      </button>
    </div>
    """
  end

  attr :deadline, Deadline, required: true
  attr :today, Date, required: true

  defp deadline_progress(assigns) do
    {total, elapsed, remaining} = Deadline.days(assigns.deadline, assigns.today)
    assigns = assign(assigns, total: total, elapsed: elapsed, remaining: remaining)

    ~H"""
    <div class="deadline">
      <div class="deadline-header">
        <button
          type="button"
          class="deadline-label button-reset"
          title="Click to edit"
          phx-click="edit_deadline"
        >
          {@deadline.label}
        </button>
        <span class="deadline-stats">{@elapsed}/{@total} days ({@remaining} remaining)</span>
      </div>
      <div class="deadline-grid">
        <div :for={block <- Deadline.grid(@deadline, @today)} class="deadline-week">
          <div
            :for={{date, kind} <- block}
            class={["deadline-day", Atom.to_string(kind)]}
            title={Date.to_iso8601(date)}
          >
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :apps, :list, required: true

  defp apps(%{apps: []} = assigns) do
    ~H"""
    <div class="empty">
      <p>No apps registered.</p>
      <p class="empty-note">Register one with <code>wave dashboard add</code>.</p>
    </div>
    """
  end

  defp apps(assigns) do
    ~H"""
    <div :for={{project, apps} <- Enum.group_by(@apps, & &1.project)} class="project">
      <div class="project-header">{project}</div>
      <ul class="branch-list">
        <li :for={app <- apps} class="branch-item">
          <a href={Apps.url(app)} target="_blank" rel="noopener noreferrer">
            <span class={["status", Atom.to_string(app.status)]} title={status_title(app.status)}></span>
            {app.branch}
            <span class="host-badge">{app.host}</span>
          </a>
        </li>
      </ul>
    </div>
    """
  end

  defp status_title(:up), do: "Responding"
  defp status_title(:down), do: "Not responding"
  defp status_title(:unknown), do: "Not checked yet"

  attr :hosts, :list, required: true

  defp hosts(assigns) do
    ~H"""
    <div class="project">
      <div class="project-header">Hosts</div>
      <ul class="branch-list">
        <li :for={host <- @hosts} class="branch-item host-item">
          <span class={["status", if(host.online?, do: "up", else: "down")]}></span>
          <span class="host-name">{host.name}</span>
          <span class="host-detail">
            {if host.online?, do: host.os, else: last_seen(host.last_seen)}
          </span>
        </li>
      </ul>
    </div>
    """
  end

  defp last_seen(nil), do: "offline"

  defp last_seen(%DateTime{} = at),
    do: "offline since #{Calendar.strftime(at, "%Y-%m-%d %H:%M")} UTC"
end
