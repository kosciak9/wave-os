import Config

config :wave_dashboard, domain: "wave.exposed"

config :wave_dashboard, WaveDashboardWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  pubsub_server: WaveDashboard.PubSub,
  render_errors: [
    formats: [html: WaveDashboardWeb.ErrorHTML, json: WaveDashboardWeb.ErrorJSON],
    layout: false
  ],
  live_view: [signing_salt: "wave-dashboard"]

config :phoenix, :json_library, JSON

config :logger, level: :info

config :logger, :default_formatter, format: "$time $metadata[$level] $message\n"
