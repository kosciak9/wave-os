defmodule WaveDashboardWeb.Router do
  use WaveDashboardWeb, :router

  @themes ~w(kanagawa-dragon kanagawa-lotus)

  @content_security_policy "default-src 'self'; script-src 'self'; style-src 'self'; " <>
                             "font-src 'self'; img-src 'self'; connect-src 'self'; " <>
                             "form-action 'self' https://duckduckgo.com; frame-ancestors 'none'"

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :protect_from_forgery
    plug :put_root_layout, html: {WaveDashboardWeb.Layouts, :root}
    plug :put_secure_browser_headers, %{"content-security-policy" => @content_security_policy}
    plug :put_theme
  end

  pipeline :fugate do
    plug :put_favicon, "/images/fugate-favicon.png"
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Must precede the dashboard's routes, which match every host.
  scope "/", WaveDashboardWeb, host: "oauth." do
    get "/*path", OAuthRelayController, :callback
  end

  scope "/", WaveDashboardWeb do
    pipe_through :browser
    live "/", HomeLive
  end

  # A separate live session, so navigating here reloads the root layout with Fugate's favicon.
  live_session :fugate do
    scope "/fugate", WaveDashboardWeb do
      pipe_through [:browser, :fugate]
      live "/", FugateLive, :index
      live "/jobs/new", FugateLive, :new
      live "/jobs/:id/edit", FugateLive, :edit
      live "/runs/:id", FugateRunLive
    end
  end

  scope "/", WaveDashboardWeb do
    get "/healthz", HealthController, :show
  end

  scope "/api", WaveDashboardWeb do
    pipe_through :api
    get "/apps", AppController, :index
    post "/apps", AppController, :create
    delete "/apps/:project/:branch", AppController, :delete
  end

  defp put_favicon(conn, path), do: assign(conn, :favicon, path)

  # The theme lives in a cookie set by the browser, so the first render already uses it.
  defp put_theme(conn, _opts) do
    conn = fetch_cookies(conn)

    theme =
      if conn.cookies["theme"] in @themes, do: conn.cookies["theme"], else: "kanagawa-dragon"

    assign(conn, :theme, theme)
  end
end
