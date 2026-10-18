defmodule WaveDashboard.Application do
  @moduledoc false
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    unless Application.get_env(:wave_dashboard, :caddy_admin_url) do
      Logger.warning("CADDY_ADMIN_URL is unset, so registered apps stay unpublished")
    end

    children = [
      {Phoenix.PubSub, name: WaveDashboard.PubSub},
      WaveDashboard.Tailnet,
      WaveDashboard.Apps,
      WaveDashboardWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: WaveDashboard.Supervisor)
  end
end
