defmodule Fugate.Herdr do
  @moduledoc """
  Herdr socket client: one NDJSON request per connection.

  Errors are `{:error, %{"code" => code, "message" => message}}` from Herdr,
  `{:error, {:transport, reason}}` when the socket could not be used, or
  `{:error, {:unexpected_response, method}}` when a result lacks what Fugate
  relies on.
  """

  alias Fugate.Herdr.Agent

  @default_timeout 10_000

  @type error :: map() | {:transport, term()} | {:unexpected_response, String.t()}

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
    case request("machine.status", %{}) do
      {:ok, %{"machines" => machines}} when is_map(machines) ->
        {:ok,
         Map.new(machines, fn {alias, machine} ->
           {alias, match?(%{"federation_reachability" => "reachable"}, machine)}
         end)}

      other ->
        unexpected(other, "machine.status")
    end
  end

  @spec create_workspace(map()) ::
          {:ok, %{workspace_id: String.t(), pane_id: String.t()}} | {:error, error()}
  def create_workspace(params) do
    case request("workspace.create", params) do
      {:ok,
       %{"workspace" => %{"workspace_id" => workspace_id}, "root_pane" => %{"pane_id" => pane_id}}}
      when is_binary(workspace_id) and is_binary(pane_id) ->
        {:ok, %{workspace_id: workspace_id, pane_id: pane_id}}

      other ->
        unexpected(other, "workspace.create")
    end
  end

  @spec start_agent(map(), timeout()) :: :ok | {:error, error()}
  def start_agent(params, timeout) do
    with {:ok, _started} <- request("agent.start", params, timeout), do: :ok
  end

  @spec get_agent(String.t()) :: {:ok, Agent.t()} | {:error, error()}
  def get_agent(target) do
    with {:ok, %{"agent" => agent}} <- request("agent.get", %{target: target}),
         {:ok, agent} <- Agent.parse(agent) do
      {:ok, agent}
    else
      other -> unexpected(other, "agent.get")
    end
  end

  @spec list_agents() :: {:ok, [Agent.t()]} | {:error, error()}
  def list_agents do
    with {:ok, %{"agents" => agents}} when is_list(agents) <- request("agent.list", %{}),
         {:ok, agents} <- parse_all(agents) do
      {:ok, agents}
    else
      other -> unexpected(other, "agent.list")
    end
  end

  @doc "Submits `text` to the agent; returns Herdr's delivery description."
  @spec prompt_agent(String.t(), String.t(), timeout()) :: {:ok, term()} | {:error, error()}
  def prompt_agent(target, text, timeout) do
    with {:ok, prompted} <- request("agent.prompt", %{target: target, text: text}, timeout) do
      {:ok, prompted["delivery"]}
    end
  end

  @spec read_agent(String.t(), pos_integer()) :: {:ok, String.t()} | {:error, error()}
  def read_agent(target, lines) do
    case request("agent.read", %{target: target, source: "recent_unwrapped", lines: lines}) do
      {:ok, %{"read" => %{"text" => text}}} when is_binary(text) -> {:ok, text}
      other -> unexpected(other, "agent.read")
    end
  end

  defp parse_all(agents) do
    parsed = Enum.map(agents, &Agent.parse/1)

    if Enum.all?(parsed, &match?({:ok, _agent}, &1)),
      do: {:ok, Enum.map(parsed, fn {:ok, agent} -> agent end)},
      else: :error
  end

  defp unexpected({:error, _reason} = error, _method), do: error
  defp unexpected(_response, method), do: {:error, {:unexpected_response, method}}

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
