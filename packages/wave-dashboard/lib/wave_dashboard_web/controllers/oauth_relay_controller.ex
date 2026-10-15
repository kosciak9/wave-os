defmodule WaveDashboardWeb.OAuthRelayController do
  @moduledoc """
  Forwards OAuth callbacks from `oauth.<domain>` to registered apps.

  OAuth providers such as Google accept only exact redirect URIs, so development apps
  share this host as their redirect URI. Before redirecting to the provider, an app stores
  its own callback URL in the `wave_oauth_return` cookie for the whole domain; the
  callback is forwarded there with its query intact, but only to a registered app's host.
  """
  use WaveDashboardWeb, :controller

  alias WaveDashboard.Apps

  @cookie "wave_oauth_return"

  def callback(conn, _params) do
    conn = fetch_cookies(conn)

    case return_uri(conn.cookies[@cookie]) do
      {:ok, uri} ->
        query = if conn.query_string == "", do: nil, else: conn.query_string

        conn
        |> delete_resp_cookie(@cookie, domain: domain(), secure: true, http_only: true)
        |> redirect(external: URI.to_string(%{uri | query: query}))

      :error ->
        conn
        |> put_status(:bad_request)
        |> text("No registered app is waiting for this OAuth callback.")
    end
  end

  defp return_uri(value) when is_binary(value) do
    with {:ok, %URI{scheme: "https", host: host} = uri} <- URI.new(value),
         true <- host in registered_hosts() do
      {:ok, uri}
    else
      _invalid -> :error
    end
  end

  defp return_uri(_missing), do: :error

  defp registered_hosts, do: Enum.map(Apps.list(), &URI.parse(Apps.url(&1)).host)

  defp domain, do: Application.fetch_env!(:wave_dashboard, :domain)
end
