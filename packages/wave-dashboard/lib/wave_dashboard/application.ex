defmodule WaveDashboard.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: WaveDashboard.PubSub},
      WaveDashboard.Tailnet,
      WaveDashboard.Apps,
      WaveDashboardWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: WaveDashboard.Supervisor)
  end
end
