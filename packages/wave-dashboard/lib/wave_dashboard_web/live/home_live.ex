defmodule WaveDashboardWeb.HomeLive do
  use WaveDashboardWeb, :live_view

  import WaveDashboardWeb.Layouts, only: [wave_logo: 1]

  alias WaveDashboard.{Agents, Apps, Clock, Deadline, Quota, Tailnet}
  alias Phoenix.LiveView.JS

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Apps.subscribe()
      Agents.subscribe()
      Quota.subscribe()
      Tailnet.subscribe()
      Deadline.subscribe()
      Clock.tick_next_minute(:tick)
    end

    {:ok,
     socket
     |> assign(
       apps: Apps.list(),
       hosts: Tailnet.hosts(),
       agents: Agents.servers(),
       quota: Quota.snapshot()
     )
     |> assign(
       editing?: false,
       deadline_error: nil,
       draft: nil,
       preview?: Application.get_env(:wave_dashboard, :preview_mode, false)
     )
     |> assign_now()
     |> assign_deadline()}
  end

  @impl true
  def handle_info({:apps, apps}, socket), do: {:noreply, assign(socket, apps: apps)}
  def handle_info({:hosts, hosts}, socket), do: {:noreply, assign(socket, hosts: hosts)}
  def handle_info({:agents, servers}, socket), do: {:noreply, assign(socket, agents: servers)}
  def handle_info({:quota, quota}, socket), do: {:noreply, assign(socket, quota: quota)}
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
      </header>

      <p :if={@preview?} class="banner" role="status">Preview / sample data, not live ahri.</p>
      <main class="dashboard-grid">
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
        <div class="dashboard-columns">
          <div class="dashboard-column">
            <.agents servers={@agents} now={@now} />
            <.hosts hosts={@hosts} now={@now} />
          </div>
          <div class="dashboard-column">
            <.apps apps={@apps} />
            <.quota snapshot={@quota} now={@now} />
          </div>
        </div>
      </main>
    </div>
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
    <section class="card deadline-editor">
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
      <div class="deadline-body">
        <div class="countdown">
          <span :if={!@expired?} class="countdown-value">
            <span>{div(@minutes_left, 60)}<span class="unit">h</span></span>
            <span>{@minutes_left |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}<span class="unit">m</span></span>
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
      </div>
    </section>
    """
  end

  attr :servers, :list, required: true
  attr :now, DateTime, required: true

  defp agents(assigns) do
    threads =
      assigns.servers
      |> Enum.flat_map(& &1.threads)
      |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

    assigns =
      assign(assigns,
        groups:
          for {state, title} <- [attention: "Needs you", working: "Working", open: "Open"],
              group = Enum.filter(threads, &(&1.state == state)),
              group != [] do
            {title, group}
          end,
        problems: Enum.reject(assigns.servers, &(&1.status in [:ok, :loading]))
      )

    ~H"""
    <section class="card agents-card" id="agents-card">
      <div class="card-header">
        <h2 class="card-title">Agents</h2>
        <span class="card-detail">{Enum.map_join(@servers, " / ", & &1.name)}</span>
      </div>
      <p :for={server <- @problems} class="banner">
        <%= if server.status == :not_configured do %>
          {server.name}: no T3 token configured.
        <% else %>
          {server.name}: T3 is not responding{if server.threads != [],
            do: ", showing the last known threads"}.
        <% end %>
      </p>
      <p :if={@groups == [] and @problems == []} class="muted">No open threads.</p>
      <div :for={{title, threads} <- @groups} class="group">
        <h3 class="group-title">{title}</h3>
        <ul class="rows">
          <li :for={thread <- threads}>
            <a href={thread.url} class="row">
              <span class="row-title">{thread.title}</span>
              <span class="row-meta sep">
                <span :if={thread.reason} class="agent-reason">{reason(thread.reason)}</span>
                <span :if={thread.project}>{thread.project}</span>
                <span>{thread.host}</span>
                <.time at={thread.updated_at} now={@now} />
              </span>
            </a>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  attr :snapshot, :map, required: true
  attr :now, DateTime, required: true

  defp quota(assigns) do
    ~H"""
    <section class="card quota-card" id="quota-card">
      <div class="card-header">
        <h2 class="card-title">CLIproxy</h2>
        <span class="card-detail">remaining</span>
      </div>
      <p :if={@snapshot.status == :loading} class="muted" role="status">Loading limits…</p>
      <p :if={@snapshot.status == :not_configured} class="muted">Quota access is not configured.</p>
      <p :if={@snapshot.status == :unavailable} class="banner" role="status">
        Quota is not responding{if @snapshot.accounts != [], do: "; last known values below"}.
      </p>
      <p :if={@snapshot.status == :ok and @snapshot.accounts == []} class="muted">
        No accounts reported.
      </p>
      <div :if={@snapshot.accounts != []} class="quota-list">
        <.quota_account
          :for={account <- Enum.take(@snapshot.accounts, 4)}
          account={account}
          snapshot={@snapshot}
          now={@now}
        />
        <details
          :if={length(@snapshot.accounts) > 4}
          class="quota-more"
          id="quota-more"
          phx-mounted={JS.ignore_attributes(["open"])}
        >
          <summary>
            {length(@snapshot.accounts) - 4} more {if length(@snapshot.accounts) == 5,
              do: "account",
              else: "accounts"}
          </summary>
          <div class="quota-extra">
            <.quota_account
              :for={account <- Enum.drop(@snapshot.accounts, 4)}
              account={account}
              snapshot={@snapshot}
              now={@now}
            />
          </div>
        </details>
      </div>
      <span :if={@snapshot.checked_at} class="card-detail">Checked
      <.time at={@snapshot.checked_at} now={@now} /></span>
    </section>
    """
  end

  attr :account, :map, required: true
  attr :snapshot, :map, required: true
  attr :now, DateTime, required: true

  defp quota_account(assigns) do
    limit = Quota.lowest(assigns.account)

    current? =
      limit != nil and Quota.current?(assigns.account, limit, assigns.snapshot, assigns.now)

    assigns = assign(assigns, limit: limit, current?: current?)

    ~H"""
    <details
      class="quota-account"
      id={"quota-" <> @account["id"]}
      phx-mounted={JS.ignore_attributes(["open"])}
    >
      <summary class="quota-summary">
        <span class="quota-heading">
          <span class="row-title">{@account["label"]}</span>
          <span :if={@limit} class={["card-detail", "sep", status_tone(@account["status"])]}>
            <span>{@limit["label"]}</span><span>{quota_caption(@account, @limit, @current?)}</span>
          </span>
        </span>
        <.quota_bar :if={@limit} limit={@limit} current?={@current?} />
        <span :if={@limit} class={["quota-value", @current? && quota_tone(@limit)]}>
          {percent(@limit["remaining_percent"])}
        </span>
        <span :if={!@limit} class={["card-detail", status_tone(@account["status"])]}>{quota_status(
          @account["status"]
        )}</span>
      </summary>
      <div class="quota-detail">
        <p class="card-detail sep">
          <span>{@account["provider"]}</span><span>{quota_status(@account["status"])}</span><span :if={
            @account["stale"]
          }>stale</span>
        </p>
        <p :if={@account["limits"] == []} class="muted">No quota data reported.</p>
        <div :for={limit <- @account["limits"]} class="quota-window">
          <div class="quota-summary">
            <span class="row-title">{limit["label"]}</span>
            <span class={[
              "quota-value",
              Quota.current?(@account, limit, @snapshot, @now) && quota_tone(limit)
            ]}>{percent(limit["remaining_percent"])}</span>
          </div>
          <.quota_bar
            :if={is_number(limit["remaining_percent"])}
            limit={limit}
            current?={Quota.current?(@account, limit, @snapshot, @now)}
          />
          <span class="card-detail">{if Quota.current?(@account, limit, @snapshot, @now),
            do: pace_label(limit),
            else: "Last known / tempo unknown"}</span>
          <span :if={is_integer(limit["reset_at"]) and limit["reset_at"] > 0} class="card-detail">
            <%= if limit["reset_at"] > DateTime.to_unix(@now) do %>
              Resets <.time at={DateTime.from_unix!(limit["reset_at"])} now={@now} />
            <% else %>
              Awaiting quota refresh
            <% end %>
          </span>
        </div>
      </div>
    </details>
    """
  end

  attr :limit, :map, required: true
  attr :current?, :boolean, required: true

  defp quota_bar(assigns) do
    assigns =
      assign(assigns,
        expected: if(assigns.current?, do: assigns.limit["pace"]["expected_remaining_percent"])
      )

    ~H"""
    <svg
      class={["quota-bar", @current? && quota_tone(@limit)]}
      viewBox="0 0 100 8"
      preserveAspectRatio="none"
      role="img"
      aria-label={bar_label(@limit, @current?, @expected)}
    >
      <rect class="quota-track" width="100" height="8" />
      <rect width={@limit["remaining_percent"] || 0} height="8" />
      <line
        :if={is_number(@expected)}
        class="quota-marker"
        vector-effect="non-scaling-stroke"
        x1={@expected}
        x2={@expected}
        y1="0"
        y2="8"
      />
    </svg>
    """
  end

  defp bar_label(limit, current?, expected) do
    tempo = if current?, do: pace_label(limit), else: "last known, tempo unknown"
    marker = if is_number(expected), do: ", expected #{percent(expected)}", else: ""
    "#{limit["label"]}: #{percent(limit["remaining_percent"])} remaining, #{tempo}#{marker}"
  end

  defp quota_caption(account, limit, current?) do
    cond do
      account["status"] != "ok" -> quota_status(account["status"])
      not current? -> "last known"
      true -> pace_label(limit)
    end
  end

  defp status_tone("cooldown"), do: "quota-critical"
  defp status_tone("error"), do: "quota-low"
  defp status_tone(_), do: nil

  defp pace_label(%{"pace" => %{"state" => "reserve"}}), do: "reserve"
  defp pace_label(%{"pace" => %{"state" => "on_pace"}}), do: "on pace"
  defp pace_label(%{"pace" => %{"state" => "deficit"}}), do: "over pace"
  defp pace_label(%{"pace" => %{"state" => "exhausted"}}), do: "exhausted"
  defp pace_label(_), do: "tempo unknown"

  defp percent(value) when is_number(value), do: "#{round(value)}%"
  defp percent(_), do: "Unknown"

  defp quota_tone(%{"pace" => %{"state" => "deficit"}}), do: "quota-low"
  defp quota_tone(%{"pace" => %{"state" => "exhausted"}}), do: "quota-critical"

  defp quota_tone(%{"pace" => %{"state" => state}}) when state in ["reserve", "on_pace"],
    do: "quota-on-pace"

  defp quota_tone(%{"remaining_percent" => percent}) when is_number(percent) and percent <= 10,
    do: "quota-critical"

  defp quota_tone(%{"remaining_percent" => percent}) when is_number(percent) and percent <= 25,
    do: "quota-low"

  defp quota_tone(_), do: nil
  defp quota_status("ok"), do: "Available"
  defp quota_status("cooldown"), do: "Cooling down"
  defp quota_status("disabled"), do: "Disabled"
  defp quota_status("error"), do: "Quota error"
  defp quota_status("unavailable"), do: "No quota data"
  defp quota_status(_), do: "Unknown quota"

  defp reason(:question), do: "question"
  defp reason(:approval), do: "approval"
  defp reason(:plan), do: "plan to review"
  defp reason(:failed), do: "failed"

  attr :apps, :list, required: true

  defp apps(assigns) do
    assigns = assign(assigns, checking: Enum.count(assigns.apps, &(&1.status == :unknown)))

    ~H"""
    <section class="card inventory-card" id="apps-card">
      <div class="card-header">
        <h2 class="card-title">Apps</h2>
        <span :if={@apps != []} class="card-detail">{Enum.count(@apps, &(&1.status == :up))}/{length(
          @apps
        )} responding<%= if @checking > 0 do %>
          / {@checking} checking
        <% end %></span>
      </div>
      <div :if={@apps == []} class="muted">
        <p>No apps registered.</p>
        <p>Register one with <code>wave dashboard add</code>.</p>
      </div>
      <div :for={{project, apps} <- Enum.group_by(@apps, & &1.project)} class="group">
        <h3 class="group-title">{project}</h3>
        <ul class="rows">
          <li :for={app <- apps}>
            <a href={Apps.url(app)} target="_blank" rel="noopener noreferrer" class="row">
              <span class="row-title" title={app.branch}>{app.branch}</span>
              <span class="row-meta sep" title={app.host}>
                <span :if={app.status != :up} class={app.status == :down && "status-error"}>{status_title(
                  app.status
                )}</span>
                <span>{app.host}</span>
              </span>
            </a>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  defp status_title(:down), do: "down"
  defp status_title(:unknown), do: "checking"

  attr :hosts, :list, required: true
  attr :now, DateTime, required: true

  defp hosts(assigns) do
    ~H"""
    <section class="card inventory-card" id="hosts-card">
      <div class="card-header">
        <h2 class="card-title">Hosts</h2>
        <span class="card-detail">{Enum.count(@hosts, & &1.online?)}/{length(@hosts)} online</span>
      </div>
      <ul class="rows">
        <li
          :for={host <- Enum.sort_by(@hosts, &(not &1.online?))}
          class={["row", not host.online? && "row-dim"]}
        >
          <span class="row-title" title={host.name}>{host.name}</span>
          <span class="row-meta">
            <%= cond do %>
              <% host.online? -> %>
                {host.os}
              <% host.last_seen -> %>
                <span class="sep"><span>offline</span><.time at={host.last_seen} now={@now} /></span>
              <% true -> %>
                offline
            <% end %>
          </span>
        </li>
      </ul>
    </section>
    """
  end

  attr :at, DateTime, default: nil
  attr :now, DateTime, required: true

  defp time(%{at: nil} = assigns), do: ~H'<span class="muted">—</span>'

  defp time(assigns) do
    ~H"""
    <time datetime={DateTime.to_iso8601(@at)} title={Clock.format(@at)}>{Clock.relative(@at, @now)}</time>
    """
  end
end
