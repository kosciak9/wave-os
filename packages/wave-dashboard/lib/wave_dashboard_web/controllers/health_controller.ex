defmodule WaveDashboardWeb.HealthController do
  use WaveDashboardWeb, :controller

  def show(conn, _params), do: text(conn, "ok")
end
