defmodule WaveDashboardWeb.AppController do
  @moduledoc """
  Registration API used by `wave dashboard`. The calling host is identified by
  its tailnet address, which Caddy passes in `X-Forwarded-For`; Caddy replaces
  any client-supplied value because it trusts no upstream proxies.
  """
  use WaveDashboardWeb, :controller

  alias WaveDashboard.Apps

  def create(conn, %{"project" => project, "branch" => branch, "port" => port}) do
    with {:ok, address} <- caller_address(conn),
         {:ok, app} <- Apps.register(address, project, branch, port) do
      json(conn, %{url: Apps.url(app)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def create(conn, _params), do: error(conn, :invalid_body)

  def delete(conn, %{"project" => project, "branch" => branch}) do
    with {:ok, address} <- caller_address(conn),
         :ok <- Apps.unregister(address, project, branch) do
      json(conn, %{status: "ok"})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp caller_address(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [address] -> {:ok, address}
      _missing -> {:error, :unknown_host}
    end
  end

  defp error(conn, reason) do
    {status, message} =
      case reason do
        :invalid_body -> {400, "expected JSON with project, branch and port"}
        :invalid_name -> {400, "project and branch need at least one letter or digit"}
        :invalid_port -> {400, "port must be an integer from 1 to 65535"}
        :unknown_host -> {403, "caller is not one of the owner's tailnet devices"}
        :not_found -> {404, "app is not registered"}
      end

    conn |> put_status(status) |> json(%{error: message})
  end
end
