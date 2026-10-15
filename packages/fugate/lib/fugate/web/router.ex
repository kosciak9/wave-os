defmodule Fugate.Web.Router do
  @moduledoc false
  use Plug.Router

  plug(Fugate.Web.Access)
  plug(:not_found_for_malformed_id)
  plug(:match)
  plug(:dispatch)

  get "/healthz" do
    send_resp(conn, 200, "ok")
  end

  forward("/api", to: Fugate.Web.JsonApiRouter)

  forward("/mcp",
    to: AshAi.Mcp.Router,
    init_opts: [
      otp_app: :fugate,
      tools: [
        :list_jobs,
        :create_job,
        :update_job,
        :delete_job,
        :trigger_run,
        :list_runs,
        :get_run,
        :abandon_run
      ]
    ]
  )

  match _ do
    send_resp(conn, 404, "not found")
  end

  @collection_routes %{"runs" => ["active", "finished"], "jobs" => []}

  # AshJsonApi answers a member path whose id is not a UUID with a generic 400.
  defp not_found_for_malformed_id(%{path_info: ["api", type, id | _]} = conn, _opts)
       when is_map_key(@collection_routes, type) do
    if id in @collection_routes[type] or match?({:ok, _uuid}, Ecto.UUID.cast(id)) do
      conn
    else
      error = %{
        status: "404",
        code: "not_found",
        title: "Not Found",
        detail: "No #{type} with id #{id}"
      }

      conn
      |> put_resp_content_type("application/vnd.api+json")
      |> send_resp(404, JSON.encode!(%{errors: [error]}))
      |> halt()
    end
  end

  defp not_found_for_malformed_id(conn, _opts), do: conn
end
