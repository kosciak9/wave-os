defmodule Fugate.Web.Access do
  @moduledoc """
  Admits loopback callers to everything and allowed tailnet clients (by their
  Tailscale host name) to everything except `/mcp`.
  """
  @behaviour Plug
  import Plug.Conn
  require Logger

  @whois_ttl :timer.minutes(1)
  @whois_timeout 5_000

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cond do
      loopback?(conn.remote_ip) -> conn
      conn.path_info |> List.first() == "mcp" -> deny(conn)
      client_name(conn.remote_ip) in Fugate.Config.get().allowed_clients -> conn
      true -> deny(conn)
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0xFFFF, high, _low}), do: div(high, 256) == 127
  defp loopback?(_ip), do: false

  defp deny(conn), do: conn |> send_resp(403, "forbidden") |> halt()

  defp client_name(ip) do
    now = System.monotonic_time(:millisecond)

    case Agent.get(__MODULE__, &Map.get(&1, ip)) do
      {name, expires_at} when expires_at > now ->
        name

      _ ->
        name = whois(ip)
        Agent.update(__MODULE__, &Map.put(&1, ip, {name, now + @whois_ttl}))
        name
    end
  end

  @doc false
  def child_spec(_opts),
    do: %{id: __MODULE__, start: {Agent, :start_link, [&Map.new/0, [name: __MODULE__]]}}

  # The first label of the node's MagicDNS name, e.g. "ahri" for "ahri.tailnet.ts.net.".
  defp whois(ip) do
    case Application.fetch_env!(:fugate, :tailscale) do
      nil ->
        Logger.warning("Denied #{:inet.ntoa(ip)}: tailscale executable not found")
        nil

      tailscale ->
        whois(tailscale, ip)
    end
  end

  defp whois(tailscale, ip) do
    task =
      Task.async(fn ->
        System.cmd(tailscale, ["whois", "--json", :inet.ntoa(ip) |> to_string()])
      end)

    with {:ok, {output, 0}} <- Task.yield(task, @whois_timeout) || Task.shutdown(task),
         {:ok, %{"Node" => %{"Name" => name}}} <- JSON.decode(output) do
      name |> String.split(".") |> hd()
    else
      other ->
        Logger.info("Denied #{:inet.ntoa(ip)}: tailscale whois gave #{inspect(other)}")
        nil
    end
  end
end
