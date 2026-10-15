defmodule WaveDashboardWeb.FugateLive do
  @moduledoc """
  Fugate's hosts, runs and jobs, and the job editor.

  The job form keeps its own draft while it is open; snapshots that arrive
  meanwhile only refresh the lists around it.
  """
  use WaveDashboardWeb, :live_view

  import WaveDashboardWeb.FugateComponents

  alias WaveDashboard.{Clock, Fugate}
  alias WaveDashboard.Fugate.Client
  alias WaveDashboard.Fugate.Client.Run

  @harnesses ~w(claude codex opencode)
  @schedules [{"Manual", "manual"}, {"Cron", "cron"}, {"Once", "once"}]
  @default_timezone "Europe/Warsaw"
  @fields ~w(name prompt repo_path harness schedule cron timezone run_at allowed_hosts enabled)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Fugate.subscribe()
      Clock.tick_next_minute(:tick)
    end

    {:ok,
     assign(socket,
       now: DateTime.utc_now(),
       snapshot: Fugate.snapshot(),
       form: nil,
       job_id: nil,
       form_errors: [],
       pending: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, apply_action(socket, socket.assigns.live_action, params)}

  defp apply_action(socket, :index, _params),
    do: assign(socket, form: nil, job_id: nil, page_title: "Fugate")

  defp apply_action(socket, :new, _params) do
    params = %{
      "harness" => "claude",
      "schedule" => "manual",
      "timezone" => @default_timezone,
      "allowed_hosts" => Enum.map(socket.assigns.snapshot.hosts, & &1.name),
      "enabled" => "true"
    }

    assign(socket,
      form: to_form(params, as: :job),
      job_id: nil,
      form_errors: [],
      page_title: "New job · Fugate"
    )
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Enum.find(socket.assigns.snapshot.jobs, &(&1.id == id)) do
      nil ->
        socket
        |> put_flash(:error, "Job not found")
        |> push_patch(to: ~p"/fugate")

      job ->
        assign(socket,
          form: to_form(job_params(job), as: :job),
          job_id: id,
          form_errors: [],
          page_title: "#{job.name} · Fugate"
        )
    end
  end

  defp job_params(job) do
    %{
      "name" => job.name,
      "prompt" => job.prompt,
      "repo_path" => job.repo_path,
      "harness" => job.harness,
      "schedule" => job.schedule,
      "cron" => job.cron,
      "timezone" => job.timezone || @default_timezone,
      "run_at" => job.run_at && Calendar.strftime(job.run_at, "%Y-%m-%dT%H:%M"),
      "allowed_hosts" => job.allowed_hosts,
      "enabled" => to_string(job.enabled)
    }
  end

  @impl true
  def handle_info({:fugate, snapshot}, socket), do: {:noreply, assign(socket, snapshot: snapshot)}

  def handle_info(:tick, socket) do
    Clock.tick_next_minute(:tick)
    {:noreply, assign(socket, now: DateTime.utc_now())}
  end

  @impl true
  def handle_event("change_job", %{"job" => params}, socket),
    do:
      {:noreply,
       assign(socket, form: to_form(params, as: :job, errors: socket.assigns.form.errors))}

  # One request at a time: the buttons are disabled meanwhile, and events sent anyway are dropped.
  def handle_event(_event, _params, %{assigns: %{pending: {_, _}}} = socket),
    do: {:noreply, socket}

  def handle_event("save_job", %{"job" => params}, socket) do
    attributes = attributes(params)
    job_id = socket.assigns.job_id

    socket
    |> assign(form: to_form(params, as: :job, errors: socket.assigns.form.errors))
    |> start_request({"save_job", job_id}, fn ->
      case job_id do
        nil -> Client.create_job(attributes)
        id -> Client.update_job(id, attributes)
      end
    end)
  end

  def handle_event("delete_job", %{"id" => id}, socket),
    do: start_request(socket, {"delete_job", id}, fn -> Client.delete_job(id) end)

  def handle_event("run_now", %{"id" => id}, socket),
    do: start_request(socket, {"run_now", id}, fn -> Client.run_now(id) end)

  def handle_event("abandon", %{"id" => id}, socket),
    do: start_request(socket, {"abandon", id}, fn -> Client.abandon(id) end)

  defp start_request(socket, pending, request),
    do: {:noreply, socket |> assign(pending: pending) |> start_async(:request, request)}

  @impl true
  def handle_async(:request, result, socket) do
    {event, _id} = socket.assigns.pending
    socket = assign(socket, pending: nil)

    case {event, result} do
      {"save_job", {:ok, result}} ->
        {:noreply, saved(socket, result)}

      {"save_job", {:exit, reason}} ->
        {:noreply, assign(socket, form_errors: [Client.describe(reason)])}

      {_event, {:ok, {:error, reason}}} ->
        {:noreply, error_flash(socket, reason)}

      {_event, {:exit, reason}} ->
        {:noreply, error_flash(socket, reason)}

      {event, {:ok, _ok}} ->
        {:noreply, done(socket, event)}
    end
  end

  defp saved(socket, {:ok, job}) do
    Fugate.refresh()

    socket
    |> put_flash(:info, "Saved #{job.name}")
    |> push_patch(to: ~p"/fugate")
  end

  defp saved(socket, {:error, {:api, _status, errors}}) do
    {field_errors, form_errors} = Enum.split_with(errors, fn {field, _} -> field in @fields end)

    errors =
      Enum.map(field_errors, fn {field, detail} ->
        {String.to_existing_atom(field), {detail, []}}
      end)

    assign(socket,
      form: to_form(socket.assigns.form.params, as: :job, errors: errors, action: :validate),
      form_errors: Enum.map(form_errors, &elem(&1, 1))
    )
  end

  defp saved(socket, {:error, reason}), do: assign(socket, form_errors: [Client.describe(reason)])

  defp done(socket, event) do
    Fugate.refresh()
    socket = clear_flash(socket)

    case event do
      "delete_job" -> socket |> put_flash(:info, "Job deleted") |> push_patch(to: ~p"/fugate")
      "run_now" -> put_flash(socket, :info, "Run queued")
      "abandon" -> put_flash(socket, :info, "Run abandoned")
    end
  end

  defp error_flash(socket, reason),
    do: socket |> clear_flash() |> put_flash(:error, Client.describe(reason))

  # Fields that do not apply to the chosen schedule are cleared, so a job never
  # keeps a stale cron expression or one-off time.
  defp attributes(params) do
    schedule = params["schedule"]

    %{
      "name" => String.trim(params["name"] || ""),
      "prompt" => params["prompt"] || "",
      "repo_path" => String.trim(params["repo_path"] || ""),
      "harness" => params["harness"],
      "schedule" => schedule,
      "cron" => if(schedule == "cron", do: blank_to_nil(params["cron"])),
      "timezone" => blank_to_nil(params["timezone"]) || @default_timezone,
      "run_at" => if(schedule == "once", do: run_at(params["run_at"])),
      "allowed_hosts" => Enum.reject(params["allowed_hosts"] || [], &(&1 == "")),
      "enabled" => params["enabled"] == "true"
    }
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp blank_to_nil(_value), do: nil

  # The datetime-local input has no zone; the form labels it as UTC.
  defp run_at(value) do
    case blank_to_nil(value) do
      nil -> nil
      <<_date::binary-size(10), "T", _hm::binary-size(5)>> = minutes -> minutes <> ":00Z"
      other -> other
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page">
      <.page_header title="Fugate" crumbs={[{"ahri.wave", ~p"/"}]}>
        <:actions :if={@live_action == :index and @snapshot.status != :not_configured}>
          <.link patch={~p"/fugate/jobs/new"} class="button">New job</.link>
        </:actions>
      </.page_header>

      <.flash flash={@flash} />
      <.connection snapshot={@snapshot} />

      <div :if={@snapshot.status != :not_configured} class="stack">
        <.stats snapshot={@snapshot} now={@now} />

        <div class="columns">
          <main class="column-main">
            <.job_form
              :if={@form}
              form={@form}
              errors={@form_errors}
              job_id={@job_id}
              hosts={host_options(@snapshot, @form)}
              pending={@pending}
            />
            <.active_runs
              runs={by_urgency(@snapshot.active_runs)}
              jobs={@snapshot.jobs}
              pending={@pending}
              now={@now}
            />
            <.recent_runs runs={@snapshot.finished_runs} jobs={@snapshot.jobs} now={@now} />
          </main>

          <aside class="column-side">
            <.jobs jobs={@snapshot.jobs} pending={@pending} now={@now} />
            <.hosts snapshot={@snapshot} />
          </aside>
        </div>
      </div>
    </div>
    """
  end

  defp host_options(snapshot, form) do
    (Enum.map(snapshot.hosts, & &1.name) ++ List.wrap(form[:allowed_hosts].value))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  attr :runs, :list, required: true
  attr :jobs, :list, required: true
  attr :pending, :any, required: true
  attr :now, DateTime, required: true

  defp active_runs(assigns) do
    ~H"""
    <section class="card">
      <div class="card-header">
        <h2 class="card-title">Active runs</h2>
        <span class="card-detail">{length(@runs)}</span>
      </div>
      <p :if={@runs == []} class="muted">Nothing running.</p>
      <ul class="run-cards">
        <li :for={run <- @runs} class={["run-card", Run.needs_attention?(run) && "run-card-stuck"]}>
          <div class="run-card-head">
            <.state_badge state={run.state} />
            <.link navigate={~p"/fugate/runs/#{run.id}"} class="row-title">
              {job_name(@jobs, run.job_id)}
            </.link>
            <span class="row-meta">{run.host || "unassigned"}</span>
          </div>
          <dl class="facts">
            <div>
              <dt>Started</dt><dd><.time at={run.inserted_at} now={@now} /></dd>
            </div>
            <div>
              <dt>Checkpoint</dt><dd><.time at={run.checkpoint_at} now={@now} /></dd>
            </div>
            <div :if={run.wake_at}>
              <dt>Wakes</dt><dd><.time at={run.wake_at} now={@now} /></dd>
            </div>
            <div :if={run.last_turn}>
              <dt>Turn</dt><dd>{run.last_turn}</dd>
            </div>
          </dl>
          <button
            type="button"
            class="button button-small button-quiet button-quiet-danger run-card-action"
            phx-click="abandon"
            phx-value-id={run.id}
            disabled={@pending != nil}
            data-confirm="Abandon this run? The agent itself is left running."
          >
            {if @pending == {"abandon", run.id}, do: "Abandoning…", else: "Abandon"}
          </button>
        </li>
      </ul>
    </section>
    """
  end

  attr :runs, :list, required: true
  attr :jobs, :list, required: true
  attr :now, DateTime, required: true

  defp recent_runs(assigns) do
    ~H"""
    <section class="card">
      <h2 class="card-title">Recent runs</h2>
      <p :if={@runs == []} class="muted">No finished runs.</p>
      <ul :if={@runs != []} class="rows">
        <li :for={run <- @runs}>
          <.link navigate={~p"/fugate/runs/#{run.id}"} class="row">
            <.state_badge state={run.state} />
            <span class="row-title">{job_name(@jobs, run.job_id)}</span>
            <span class="row-meta sep">
              <span>{run.host || "—"}</span>
              <.time at={run.finished_at || run.updated_at} now={@now} />
            </span>
          </.link>
        </li>
      </ul>
    </section>
    """
  end

  attr :jobs, :list, required: true
  attr :pending, :any, required: true
  attr :now, DateTime, required: true

  defp jobs(assigns) do
    ~H"""
    <section class="card">
      <div class="card-header">
        <h2 class="card-title">Jobs</h2>
        <span class="card-detail">{Enum.count(@jobs, & &1.enabled)}/{length(@jobs)} enabled</span>
      </div>
      <p :if={@jobs == []} class="muted">No jobs yet.</p>
      <ul :if={@jobs != []} class="rows">
        <li :for={job <- @jobs} class={["row", not job.enabled && "row-dim"]}>
          <div class="row-stack">
            <.link patch={~p"/fugate/jobs/#{job.id}/edit"} class="row-title">{job.name}</.link>
            <span class="row-meta sep">
              <span>{job.harness}</span>
              <span>{schedule(job)}</span>
              <span :if={job.enabled and job.next_run_at}>
                next <.time at={job.next_run_at} now={@now} />
              </span>
              <span :if={not job.enabled}>disabled</span>
            </span>
          </div>
          <button
            type="button"
            class="button button-small button-quiet"
            phx-click="run_now"
            phx-value-id={job.id}
            disabled={@pending != nil}
          >
            {if @pending == {"run_now", job.id}, do: "Queuing…", else: "Run"}
          </button>
        </li>
      </ul>
    </section>
    """
  end

  defp schedule(%{schedule: "cron"} = job), do: job.cron
  defp schedule(job), do: job.schedule

  attr :snapshot, :any, required: true

  defp hosts(assigns) do
    ~H"""
    <section class="card">
      <h2 class="card-title">Hosts</h2>
      <p :if={@snapshot.hosts == []} class="muted">No hosts.</p>
      <ul :if={@snapshot.hosts != []} class="rows">
        <li :for={host <- @snapshot.hosts} class="row">
          <span
            class={["status", reachability(host.reachable)]}
            title={reachability_title(host.reachable)}
          ></span>
          <div class="row-stack">
            <span class="row-title mono">{host.name}</span>
            <span :if={host.harnesses != []} class="row-meta">{Enum.join(host.harnesses, ", ")}</span>
          </div>
          <span
            :if={host.max_concurrent}
            class="slots"
            role="img"
            aria-label={"#{host.active_runs} of #{host.max_concurrent} slots busy"}
            title={"#{host.active_runs}/#{host.max_concurrent} running"}
          >
            <span
              :for={slot <- 1..host.max_concurrent//1}
              class={["slot", slot <= host.active_runs && "busy"]}
            ></span>
          </span>
          <span :if={!host.max_concurrent} class="row-meta">{host.active_runs} running</span>
        </li>
      </ul>
    </section>
    """
  end

  defp reachability(true), do: "up"
  defp reachability(false), do: "down"
  defp reachability(nil), do: "unknown"

  defp reachability_title(true), do: "Reachable"
  defp reachability_title(false), do: "Unreachable"
  defp reachability_title(nil), do: "Not checked yet"

  attr :form, Phoenix.HTML.Form, required: true
  attr :errors, :list, required: true
  attr :job_id, :string, required: true
  attr :hosts, :list, required: true
  attr :pending, :any, required: true

  defp job_form(assigns) do
    assigns =
      assign(assigns,
        editing?: assigns.job_id != nil,
        saving?: match?({"save_job", _id}, assigns.pending),
        harnesses: @harnesses,
        schedules: @schedules,
        schedule: assigns.form[:schedule].value,
        allowed: List.wrap(assigns.form[:allowed_hosts].value)
      )

    ~H"""
    <section class="card card-focus">
      <h2 class="card-title">{if @editing?, do: "Edit job", else: "New job"}</h2>
      <p :for={error <- @errors} class="form-error" role="alert">{error}</p>
      <.form for={@form} id="job-form" phx-change="change_job" phx-submit="save_job" class="job-form">
        <.field field={@form[:name]} label="Name">
          <input
            type="text"
            id={@form[:name].id}
            name={@form[:name].name}
            value={@form[:name].value}
            required
          />
        </.field>
        <.field field={@form[:prompt]} label="Prompt">
          <textarea id={@form[:prompt].id} name={@form[:prompt].name} rows="8" required>{Phoenix.HTML.Form.normalize_value("textarea", @form[:prompt].value)}</textarea>
        </.field>
        <.field field={@form[:repo_path]} label="Repository path">
          <input
            type="text"
            id={@form[:repo_path].id}
            name={@form[:repo_path].name}
            value={@form[:repo_path].value}
            placeholder="/Users/…/project"
            class="mono"
            required
          />
        </.field>
        <div class="field-row">
          <.field field={@form[:harness]} label="Harness">
            <select id={@form[:harness].id} name={@form[:harness].name}>
              {Phoenix.HTML.Form.options_for_select(@harnesses, @form[:harness].value)}
            </select>
          </.field>
          <.field field={@form[:schedule]} label="Schedule">
            <select id={@form[:schedule].id} name={@form[:schedule].name}>
              {Phoenix.HTML.Form.options_for_select(@schedules, @schedule)}
            </select>
          </.field>
        </div>
        <div :if={@schedule == "cron"} class="field-row">
          <.field field={@form[:cron]} label="Cron (5 fields)">
            <input
              type="text"
              id={@form[:cron].id}
              name={@form[:cron].name}
              value={@form[:cron].value}
              placeholder="0 9 * * 1-5"
              class="mono"
              required
            />
          </.field>
          <.field field={@form[:timezone]} label="Time zone">
            <input
              type="text"
              id={@form[:timezone].id}
              name={@form[:timezone].name}
              value={@form[:timezone].value}
            />
          </.field>
        </div>
        <.field :if={@schedule == "once"} field={@form[:run_at]} label="Run at (UTC)">
          <input
            type="datetime-local"
            id={@form[:run_at].id}
            name={@form[:run_at].name}
            value={@form[:run_at].value}
            required
          />
        </.field>
        <fieldset class="field">
          <legend>Allowed hosts</legend>
          <input type="hidden" name={@form[:allowed_hosts].name <> "[]"} value="" />
          <label :for={host <- @hosts} class="check">
            <input
              type="checkbox"
              name={@form[:allowed_hosts].name <> "[]"}
              value={host}
              checked={host in @allowed}
            />
            {host}
          </label>
          <p :for={{message, _} <- @form[:allowed_hosts].errors} class="form-error">{message}</p>
        </fieldset>
        <label class="check">
          <input type="hidden" name={@form[:enabled].name} value="false" />
          <input
            type="checkbox"
            name={@form[:enabled].name}
            value="true"
            checked={@form[:enabled].value == "true"}
          /> Enabled
        </label>
        <div class="row-actions">
          <button type="submit" class="button" disabled={@saving?}>
            {if @saving?, do: "Saving…", else: "Save"}
          </button>
          <.link patch={~p"/fugate"} class="button button-quiet">Cancel</.link>
          <button
            :if={@editing?}
            type="button"
            class="button button-danger row-actions-end"
            phx-click="delete_job"
            phx-value-id={@job_id}
            disabled={@pending != nil}
            data-confirm={"Delete #{@form[:name].value} and its run history?"}
          >
            {if @pending == {"delete_job", @job_id}, do: "Deleting…", else: "Delete job"}
          </button>
        </div>
      </.form>
    </section>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp field(assigns) do
    ~H"""
    <div class="field">
      <label for={@field.id}>{@label}</label>
      {render_slot(@inner_block)}
      <p :for={{message, _} <- @field.errors} class="form-error">{message}</p>
    </div>
    """
  end
end
