defmodule WaveDashboardWeb.Router do
  use WaveDashboardWeb, :router

  @themes ~w(kanagawa kanagawa-lotus)

  @content_security_policy "default-src 'self'; script-src 'self'; style-src 'self'; " <>
                             "font-src 'self'; img-src 'self'; connect-src 'self'; " <>
                             "form-action 'self' https://duckduckgo.com; frame-ancestors 'none'"

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :protect_from_forgery
    plug :put_root_layout, html: {WaveDashboardWeb.Layouts, :root}
    plug :put_secure_browser_headers, %{"content-security-policy" => @content_security_policy}
    plug :put_theme
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", WaveDashboardWeb do
    pipe_through :browser
    live "/", HomeLive
  end

  scope "/", WaveDashboardWeb do
    get "/healthz", HealthController, :show
  end

  scope "/api", WaveDashboardWeb do
    pipe_through :api
    post "/apps", AppController, :create
    delete "/apps/:project/:branch", AppController, :delete
  end

  # The theme lives in a cookie set by the browser, so the first render already uses it.
  defp put_theme(conn, _opts) do
    conn = fetch_cookies(conn)
    theme = if conn.cookies["theme"] in @themes, do: conn.cookies["theme"], else: "kanagawa"
    assign(conn, :theme, theme)
  end
end
