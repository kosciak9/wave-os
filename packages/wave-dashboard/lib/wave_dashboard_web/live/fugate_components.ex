defmodule WaveDashboardWeb.FugateComponents do
  @moduledoc false
  use WaveDashboardWeb, :html

  alias WaveDashboard.Fugate.{Client, Snapshot}

  attr :title, :string, required: true
  attr :back, :string, required: true
  attr :back_label, :string, required: true
  slot :actions

  def page_header(assigns) do
    ~H"""
    <header class="page-header">
      <.link navigate={@back} class="page-back">← {@back_label}</.link>
      <h1 class="page-title">{@title}</h1>
      <div :if={@actions != []} class="page-actions">{render_slot(@actions)}</div>
      <img src={~p"/images/fugate.png"} alt="Fugate" class="page-logo" />
    </header>
    """
  end

  attr :flash, :map, required: true

  def flash(assigns) do
    ~H"""
    <p :if={message = Phoenix.Flash.get(@flash, :error)} class="error flash" role="alert">
      {message}
    </p>
    <p :if={message = Phoenix.Flash.get(@flash, :info)} class="notice flash" role="status">
      {message}
    </p>
    """
  end

  @doc "Explains a snapshot that is not current, so stale data is never mistaken for live data."
  attr :snapshot, Snapshot, required: true

  def connection(%{snapshot: %Snapshot{status: :ok}} = assigns), do: ~H""

  def connection(%{snapshot: %Snapshot{status: :not_configured}} = assigns) do
    ~H"""
    <div class="empty">
      <p>Fugate is not configured.</p>
      <p class="empty-note">Set <code>FUGATE_URL</code> for the dashboard service.</p>
    </div>
    """
  end

  def connection(%{snapshot: %Snapshot{status: :loading}} = assigns) do
    ~H"""
    <p class="notice">Loading…</p>
    """
  end

  def connection(%{snapshot: %Snapshot{status: {:error, reason}}} = assigns) do
    assigns = assign(assigns, :reason, Client.describe(reason))

    ~H"""
    <p class="error" role="alert">
      {@reason}.<span :if={@snapshot.jobs != []}> Showing the last known state.</span>
    </p>
    """
  end

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

  def job_name(jobs, job_id) do
    case Enum.find(jobs, &(&1.id == job_id)) do
      nil -> "deleted job"
      job -> job.name
    end
  end

  def format_time(nil), do: "—"
  def format_time(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
end
