defmodule Fugate.Herdr do
  @moduledoc """
  Herdr socket client: one NDJSON request per connection.

  Errors are `{:error, %{"code" => code, "message" => message}}` from Herdr or
  `{:error, {:transport, reason}}` when the socket could not be used.
  """

  @default_timeout 10_000

  @type error :: %{String.t() => String.t()} | {:transport, term()}

  @spec request(String.t(), map(), timeout()) :: {:ok, map()} | {:error, error()}
  def request(method, params, timeout \\ @default_timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    id = Integer.to_string(System.unique_integer([:positive]))
    line = JSON.encode!(%{id: id, method: method, params: params}) <> "\n"

    with {:ok, socket} <- connect(timeout) do
      try do
        with :ok <- transport(:gen_tcp.send(socket, line)),
             {:ok, response} <- read_line(socket, "", deadline) do
          decode(response, id)
        end
      after
        :gen_tcp.close(socket)
      end
    end
  end

  @doc "Opens a socket for a long-lived stream such as `events.subscribe`."
  @spec connect(timeout()) :: {:ok, :gen_tcp.socket()} | {:error, error()}
  def connect(timeout \\ @default_timeout) do
    path = Application.fetch_env!(:fugate, :herdr_socket)

    {:local, path}
    |> :gen_tcp.connect(0, [:binary, active: false, packet: :raw], timeout)
    |> transport()
  end

  @doc "Maps saved-machine alias to whether the coordinator currently reaches it."
  @spec machine_reachability() :: {:ok, %{String.t() => boolean()}} | {:error, error()}
  def machine_reachability do
    with {:ok, %{"machines" => machines}} <- request("machine.status", %{}) do
      {:ok,
       Map.new(machines, fn {alias, machine} ->
         {alias, machine["federation_reachability"] == "reachable"}
       end)}
    end
  end

  defp read_line(socket, buffer, deadline) do
    case :binary.split(buffer, "\n") do
      [line, _rest] ->
        {:ok, line}

      [_incomplete] ->
        remaining = max(deadline - System.monotonic_time(:millisecond), 0)

        case :gen_tcp.recv(socket, 0, remaining) do
          {:ok, data} -> read_line(socket, buffer <> data, deadline)
          {:error, reason} -> {:error, {:transport, reason}}
        end
    end
  end

  defp decode(line, id) do
    case JSON.decode(line) do
      {:ok, %{"id" => ^id, "result" => result}} -> {:ok, result}
      {:ok, %{"error" => error}} -> {:error, error}
      {:ok, other} -> {:error, {:transport, {:unexpected_response, other}}}
      {:error, reason} -> {:error, {:transport, {:invalid_json, reason}}}
    end
  end

  defp transport({:error, reason}), do: {:error, {:transport, reason}}
  defp transport(ok), do: ok
end
