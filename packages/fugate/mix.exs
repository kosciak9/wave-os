defmodule Fugate.MixProject do
  use Mix.Project

  def project do
    [
      app: :fugate,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [fugate: [include_executables_for: [:unix]]]
    ]
  end

  def application do
    [
      mod: {Fugate.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ash, "~> 3.36"},
      {:ash_sqlite, "0.2.19"},
      {:ash_json_api, "~> 1.7"},
      {:ash_ai, "~> 1.2"},
      {:bandit, "~> 1.12"},
      {:crontab, "~> 1.2"},
      {:tz, "~> 0.28"}
    ]
  end
end
