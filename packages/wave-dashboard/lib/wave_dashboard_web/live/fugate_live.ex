defmodule WaveDashboardWeb.FugateLive do
  @moduledoc """
  Fugate's hosts, runs and jobs, and the job editor.

  The job form keeps its own draft while it is open; snapshots that arrive
  meanwhile only refresh the lists around it.
  """
  use WaveDashboardWeb, :live_view

  import WaveDashboardWeb.FugateComponents

  alias WaveDashboard.Fugate
  alias WaveDashboard.Fugate.Client

  @harnesses ~w(claude codex opencode)
  @schedules [{"Manual", "manual"}, {"Cron", "cron"}, {"Once", "once"}]
  @default_timezone "Europe/Warsaw"
  @fields ~w(name prompt repo_path harness schedule cron timezone run_at allowed_hosts enabled)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Fugate.subscribe()

    {:ok,
     assign(socket,
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

  def handle_event("toggle_job", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.snapshot.jobs, &(&1.id == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Job not found")}

      job ->
        enabled = not job.enabled

        start_request(socket, {"toggle_job", id}, fn ->
          Client.update_job(id, %{"enabled" => enabled})
        end)
    end
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
      "toggle_job" -> socket
      "delete_job" -> put_flash(socket, :info, "Job deleted")
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
    <div class="container fugate">
      <.page_header title="Fugate" back={~p"/"} back_label="Wave">
        <:actions :if={@live_action == :index and @snapshot.status != :not_configured}>
          <.link patch={~p"/fugate/jobs/new"} class="button">New job</.link>
        </:actions>
      </.page_header>

      <.flash flash={@flash} />
      <.connection snapshot={@snapshot} />

      <.job_form
        :if={@form}
        form={@form}
        errors={@form_errors}
        editing?={@job_id != nil}
        hosts={host_options(@snapshot, @form)}
        saving?={match?({"save_job", _id}, @pending)}
      />

      <main :if={@snapshot.status != :not_configured}>
        <.hosts snapshot={@snapshot} />
        <.active_runs runs={@snapshot.active_runs} jobs={@snapshot.jobs} pending={@pending} />
        <.jobs jobs={@snapshot.jobs} pending={@pending} />
        <.recent_runs
          runs={@snapshot.finished_runs}
          jobs={@snapshot.jobs}
        />
      </main>
    </div>
    """
  end

  defp host_options(snapshot, form) do
    (Enum.map(snapshot.hosts, & &1.name) ++ List.wrap(form[:allowed_hosts].value))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  attr :snapshot, :any, required: true

  defp hosts(assigns) do
    ~H"""
    <section class="project">
      <div class="project-header section-header">
        Hosts
        <span :if={@snapshot.max_concurrent} class="section-detail">
          {@snapshot.hosts |> Enum.map(& &1.active_runs) |> Enum.sum()}/{@snapshot.max_concurrent} running
        </span>
      </div>
      <ul class="branch-list">
        <li :for={host <- @snapshot.hosts} class="branch-item host-item">
          <span
            class={["status", reachability(host.reachable)]}
            title={reachability_title(host.reachable)}
          ></span>
          <span class="host-name">{host.name}</span>
          <span class="host-detail">
            {host.active_runs}/{host.max_concurrent || "—"}
            <span :if={host.harnesses != []}>· {Enum.join(host.harnesses, ", ")}</span>
          </span>
        </li>
        <li :if={@snapshot.hosts == []} class="branch-item muted">No hosts.</li>
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

  attr :runs, :list, required: true
  attr :jobs, :list, required: true
  attr :pending, :any, required: true

  defp active_runs(assigns) do
    ~H"""
    <section class="project">
      <div class="project-header">Active runs</div>
      <ul class="branch-list">
        <li :for={run <- @runs} class="branch-item run-item">
          <div class="run-line">
            <.link navigate={~p"/fugate/runs/#{run.id}"} class="run-job">{job_name(@jobs, run.job_id)}</.link>
            <.state_badge state={run.state} />
            <span class="host-badge">{run.host || "unassigned"}</span>
          </div>
          <dl class="run-facts">
            <div :if={run.wake_at}>
              <dt>Wakes</dt><dd>{format_time(run.wake_at)}</dd>
            </div>
            <div>
              <dt>Turn</dt><dd>{run.last_turn || "—"}</dd>
            </div>
            <div>
              <dt>Checkpoint</dt><dd>{format_time(run.checkpoint_at)}</dd>
            </div>
            <div :if={run.workspace_id || run.pane_id}>
              <dt>Pane</dt>
              <dd class="mono">{run.workspace_id || "—"} / {run.pane_id || "—"}</dd>
            </div>
          </dl>
          <div class="row-actions">
            <button
              type="button"
              class="button button-danger"
              phx-click="abandon"
              phx-value-id={run.id}
              disabled={@pending != nil}
              data-confirm="Abandon this run? The agent itself is left running."
            >
              {if @pending == {"abandon", run.id}, do: "Abandoning…", else: "Abandon"}
            </button>
          </div>
        </li>
        <li :if={@runs == []} class="branch-item muted">Nothing running.</li>
      </ul>
    </section>
    """
  end

  attr :jobs, :list, required: true
  attr :pending, :any, required: true

  defp jobs(assigns) do
    ~H"""
    <section class="project">
      <div class="project-header">Jobs</div>
      <ul class="branch-list">
        <li :for={job <- @jobs} class={["branch-item", "job-item", not job.enabled && "disabled"]}>
          <div class="run-line">
            <.link patch={~p"/fugate/jobs/#{job.id}/edit"} class="run-job">{job.name}</.link>
            <span class="host-badge">{job.harness} · {schedule(job)}</span>
          </div>
          <dl class="run-facts">
            <div>
              <dt>Repo</dt><dd class="mono">{job.repo_path}</dd>
            </div>
            <div>
              <dt>Hosts</dt><dd>{Enum.join(job.allowed_hosts, ", ")}</dd>
            </div>
            <div>
              <dt>Next</dt><dd>{format_time(job.next_run_at)}</dd>
            </div>
          </dl>
          <div class="row-actions">
            <button
              type="button"
              class="button"
              phx-click="run_now"
              phx-value-id={job.id}
              disabled={@pending != nil}
            >
              {if @pending == {"run_now", job.id}, do: "Queuing…", else: "Run now"}
            </button>
            <button
              type="button"
              class="button button-quiet"
              phx-click="toggle_job"
              phx-value-id={job.id}
              disabled={@pending != nil}
            >
              {if job.enabled, do: "Disable", else: "Enable"}
            </button>
            <.link patch={~p"/fugate/jobs/#{job.id}/edit"} class="button button-quiet">Edit</.link>
            <button
              type="button"
              class="button button-danger"
              phx-click="delete_job"
              phx-value-id={job.id}
              disabled={@pending != nil}
              data-confirm={"Delete #{job.name} and its run history?"}
            >
              {if @pending == {"delete_job", job.id}, do: "Deleting…", else: "Delete"}
            </button>
          </div>
        </li>
        <li :if={@jobs == []} class="branch-item muted">No jobs yet.</li>
      </ul>
    </section>
    """
  end

  defp schedule(%{schedule: "cron"} = job), do: "#{job.cron} #{job.timezone}"
  defp schedule(%{schedule: "once"} = job), do: "once #{format_time(job.run_at)}"
  defp schedule(job), do: job.schedule

  attr :runs, :list, required: true
  attr :jobs, :list, required: true

  defp recent_runs(assigns) do
    ~H"""
    <section class="project">
      <div class="project-header">Recent runs</div>
      <ul class="branch-list">
        <li :for={run <- @runs} class="branch-item">
          <.link navigate={~p"/fugate/runs/#{run.id}"} class="run-line">
            <span class="run-job">{job_name(@jobs, run.job_id)}</span>
            <.state_badge state={run.state} />
            <span class="host-badge">
              {run.host || "—"} · {format_time(run.finished_at || run.updated_at)}
            </span>
          </.link>
        </li>
        <li :if={@runs == []} class="branch-item muted">No finished runs.</li>
      </ul>
    </section>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :errors, :list, required: true
  attr :editing?, :boolean, required: true
  attr :hosts, :list, required: true
  attr :saving?, :boolean, required: true

  defp job_form(assigns) do
    assigns =
      assign(assigns,
        harnesses: @harnesses,
        schedules: @schedules,
        schedule: assigns.form[:schedule].value,
        allowed: List.wrap(assigns.form[:allowed_hosts].value)
      )

    ~H"""
    <section class="deadline job-editor">
      <h2 class="project-header editor-title">{if @editing?, do: "Edit job", else: "New job"}</h2>
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
