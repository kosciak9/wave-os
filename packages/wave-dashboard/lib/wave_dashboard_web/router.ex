defmodule WaveDashboardWeb.Router do
  use WaveDashboardWeb, :router

  @content_security_policy "default-src 'self'; script-src 'self'; style-src 'self'; " <>
                             "font-src 'self'; img-src 'self'; connect-src 'self'; " <>
                             "form-action 'self'; frame-ancestors 'none'"

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :protect_from_forgery
    plug :put_root_layout, html: {WaveDashboardWeb.Layouts, :root}
    plug :put_secure_browser_headers, %{"content-security-policy" => @content_security_policy}
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Must precede the dashboard's routes, which match every host.
  scope "/", WaveDashboardWeb, host: "oauth." do
    get "/*path", OAuthRelayController, :callback
  end

  # One live session, so every page change happens in place and can animate.
  live_session :default do
    scope "/", WaveDashboardWeb do
      pipe_through :browser
      live "/", HomeLive
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
end
