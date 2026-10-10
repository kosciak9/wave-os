defmodule WaveDashboard.Caddy do
  @moduledoc """
  Derives Caddy's whole configuration from the registered apps and loads it
  through the admin API when the running configuration differs.

  Apps are grouped by project and host under a wildcard site such as
  `*.firmowid.jayce.wave.exposed`, so Caddy obtains one wildcard certificate per
  group and branch names never reach certificate transparency logs.
  """

  alias WaveDashboard.Apps.App

  @request_timeout :timer.seconds(10)

  def sync(apps) do
    desired = config(apps)

    with {:ok, running} <- request(:get, "/config/") do
      if JSON.decode(running) == {:ok, desired}, do: :ok, else: load(desired)
    end
  end

  defp load(config) do
    with {:ok, _body} <- request(:post, "/load", JSON.encode!(config)), do: :ok
  end

  def config(apps) do
    domain = Application.fetch_env!(:wave_dashboard, :domain)
    admin = URI.parse(admin_url())

    %{
      "admin" => %{"listen" => "#{admin.host}:#{admin.port}"},
      "apps" => %{
        "http" => %{
          "servers" => %{
            "wave" => %{
              "listen" => [":443"],
              "automatic_https" => %{"disable_redirects" => true},
              "routes" => [dashboard_route(domain) | app_routes(apps, domain)]
            }
          }
        },
        "tls" => %{
          "automation" => %{
            "policies" => [
              %{
                "issuers" => [
                  %{
                    "module" => "acme",
                    "challenges" => %{
                      "dns" => %{
                        "provider" => %{
                          "name" => "cloudflare",
                          "api_token" => "{env.CLOUDFLARE_API_TOKEN}"
                        }
                      }
                    }
                  }
                ]
              }
            ]
          }
        }
      }
    }
  end

  defp dashboard_route(domain) do
    port = Application.fetch_env!(:wave_dashboard, WaveDashboardWeb.Endpoint)[:http][:port]
    route([domain], [proxy("127.0.0.1:#{port}")])
  end

  defp app_routes(apps, domain) do
    apps
    |> Enum.group_by(&{&1.project, &1.host})
    |> Enum.sort()
    |> Enum.map(fn {{project, host}, group} ->
      branches =
        group
        |> Enum.sort_by(& &1.branch)
        |> Enum.map(&route([App.hostname(&1, domain)], [proxy("#{&1.address}:#{&1.port}")]))

      not_found = %{"handle" => [%{"handler" => "static_response", "status_code" => 404}]}

      route(["*.#{project}.#{host}.#{domain}"], [
        %{"handler" => "subroute", "routes" => branches ++ [not_found]}
      ])
    end)
  end

  defp route(hosts, handlers),
    do: %{"match" => [%{"host" => hosts}], "handle" => handlers, "terminal" => true}

  defp proxy(dial), do: %{"handler" => "reverse_proxy", "upstreams" => [%{"dial" => dial}]}

  defp admin_url, do: Application.fetch_env!(:wave_dashboard, :caddy_admin_url)

  defp request(method, path, body \\ nil) do
    url = String.to_charlist(admin_url() <> path)

    request =
      case body do
        nil -> {url, []}
        body -> {url, [], ~c"application/json", body}
      end

    case :httpc.request(method, request, [timeout: @request_timeout], body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, response}} -> {:ok, response}
      {:ok, {{_version, status, _reason}, _headers, response}} -> {:error, {status, response}}
      {:error, reason} -> {:error, reason}
    end
  end
end
