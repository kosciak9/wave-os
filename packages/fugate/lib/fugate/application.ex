defmodule Fugate.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    config = Fugate.Config.load!()

    children = [
      Fugate.Repo,
      {Ecto.Migrator, repos: Application.fetch_env!(:fugate, :ecto_repos)},
      Fugate.Scheduler,
      Fugate.Herdr.Events,
      Fugate.Web.Access,
      {
        Bandit,
        # Only HTTP/1.1 is served; Bandit's HTTP/2 has an open advisory.
        plug: Fugate.Web.Router,
        ip: config.bind,
        port: config.port,
        http_2_options: [enabled: false]
      }
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: Fugate.Supervisor)
  end
end
