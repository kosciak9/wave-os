defmodule WaveDashboardWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :wave_dashboard

  @session_options [
    store: :cookie,
    key: "_wave_dashboard_key",
    signing_salt: "wave-dashboard-session",
    same_site: "Lax",
    secure: true
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  plug Plug.Static, at: "/", from: :wave_dashboard, only: WaveDashboardWeb.static_paths()

  # The LiveView client ships prebuilt with its packages, so no asset bundler is needed.
  plug Plug.Static, at: "/vendor", from: {:phoenix, "priv/static"}, only: ~w(phoenix.min.js)

  plug Plug.Static,
    at: "/vendor",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.min.js)

  plug Plug.Parsers,
    parsers: [:urlencoded, :json],
    pass: ["*/*"],
    json_decoder: JSON,
    length: 16_384

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug WaveDashboardWeb.Router
end
