defmodule WaveDashboard.Agents do
  @moduledoc """
  Open T3 Code threads on each configured server, read from its orchestration
  snapshot with a read-only token and broadcast whenever they change.

  T3 servers do not federate, so each one is polled on its own; a server that
  stops answering keeps its last threads, shown as stale.
  """
  use GenServer
  require Logger

  @poll_interval :timer.seconds(5)
  @connect_timeout :timer.seconds(2)
  @request_timeout :timer.seconds(4)
  @topic "agents"

  defmodule Thread do
    @moduledoc """
    `state` is `:attention` (a question, an approval, a plan to review or a
    failure; `reason` says which), `:working` or `:open`. `url` opens the
    thread in the T3 Code app.
    """
    @enforce_keys [:id, :host, :title, :project, :state, :updated_at, :url]
    defstruct @enforce_keys ++ [:reason]
  end

  defmodule Server do
    @moduledoc """
    `status` is `:loading`, `:ok`, `:not_configured` while its token is
    missing, or `{:error, reason}`, which keeps the previous threads.
    """
    @enforce_keys [:name, :url]
    defstruct @enforce_keys ++ [status: :loading, threads: []]
  end

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(WaveDashboard.PubSub, @topic)

  def servers, do: GenServer.call(__MODULE__, :servers)

  @impl true
  def init(nil) do
    servers =
      Application.fetch_env!(:wave_dashboard, :t3_servers)
      |> Map.new(fn {name, url} -> {name, %Server{name: name, url: url}} end)

    for name <- Map.keys(servers), do: send(self(), {:poll, name})
    {:ok, %{servers: servers, polls: %{}}}
  end

  @impl true
  def handle_call(:servers, _from, state), do: {:reply, sorted(state.servers), state}

  @impl true
  def handle_info({:poll, name}, state) do
    %Server{url: url} = state.servers[name]
    token_path = token_path(name)
    # Unlinked, so a snapshot the dashboard cannot parse never takes it down.
    task =
      Task.Supervisor.async_nolink(WaveDashboard.TaskSupervisor, fn ->
        fetch(name, url, token_path)
      end)

    {:noreply, put_in(state.polls[task.ref], name)}
  end

  def handle_info({ref, result}, %{polls: polls} = state) when is_map_key(polls, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_poll(state, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{polls: polls} = state)
      when is_map_key(polls, ref),
      do: {:noreply, finish_poll(state, ref, {:error, {:crashed, reason}})}

  defp finish_poll(state, ref, result) do
    name = state.polls[ref]
    Process.send_after(self(), {:poll, name}, @poll_interval)
    server = apply_result(state.servers[name], result)
    servers = Map.put(state.servers, name, server)
    if servers != state.servers, do: publish(servers)
    %{state | servers: servers, polls: Map.delete(state.polls, ref)}
  end

  defp apply_result(server, {:ok, threads}), do: %{server | status: :ok, threads: threads}

  defp apply_result(server, {:error, :not_configured}),
    do: %{server | status: :not_configured, threads: []}

  defp apply_result(server, {:error, reason}) do
    if server.status != {:error, reason},
      do: Logger.warning("T3 server #{server.name} poll failed: #{inspect(reason)}")

    %{server | status: {:error, reason}}
  end

  defp sorted(servers), do: servers |> Map.values() |> Enum.sort_by(& &1.name)

  # Tokens are systemd credentials named `t3-<server>`.
  defp token_path(name) do
    case Application.fetch_env!(:wave_dashboard, :credentials_directory) do
      nil -> nil
      directory -> Path.join(directory, "t3-" <> name)
    end
  end

  defp fetch(name, url, token_path) do
    with {:ok, token} <- read_token(token_path),
         {:ok, %{"environmentId" => environment_id}} <-
           get(url <> "/.well-known/t3/environment", []),
         {:ok, shell} <-
           get(url <> "/api/orchestration/shell", [
             {~c"authorization", String.to_charlist("Bearer " <> token)},
             {~c"x-t3-orchestration-protocol", ~c"2"}
           ]) do
      {:ok, threads(shell, name, environment_id, DateTime.utc_now())}
    end
  end

  defp read_token(nil), do: {:error, :not_configured}

  defp read_token(path) do
    case File.read(path) do
      {:ok, token} -> {:ok, String.trim(token)}
      {:error, :enoent} -> {:error, :not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get(url, headers) do
    http_options = [
      timeout: @request_timeout,
      connect_timeout: @connect_timeout,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    case :httpc.request(:get, {String.to_charlist(url), headers}, http_options,
           body_format: :binary
         ) do
      {:ok, {{_version, 200, _reason}, _headers, body}} -> JSON.decode(body)
      {:ok, {{_version, status, _reason}, _headers, _body}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The threads T3's sidebar lists as active: not archived, settled or snoozed,
  # and not subagents, which belong to the thread that delegated them.
  defp threads(shell, host, environment_id, now) do
    projects = Map.new(shell["projects"], &{&1["id"], &1["title"]})

    shell["threads"]
    |> Enum.filter(&open?(&1, now))
    |> Enum.map(fn thread ->
      {state, reason} = state(thread)

      %Thread{
        id: thread["id"],
        host: host,
        title: thread["title"],
        project: projects[thread["projectId"]],
        state: state,
        reason: reason,
        updated_at: datetime(thread["updatedAt"]),
        url: "t3code://threads/#{segment(environment_id)}/#{segment(thread["id"])}"
      }
    end)
  end

  defp open?(thread, now) do
    thread["archivedAt"] == nil and thread["lineage"]["parentThreadId"] == nil and
      thread["settledOverride"] != "settled" and not snoozed?(thread["snoozedUntil"], now)
  end

  defp snoozed?(nil, _now), do: false
  defp snoozed?(until, now), do: DateTime.after?(datetime(until), now)

  defp state(%{"pendingRuntimeRequest" => %{"kind" => "user_input"}}), do: {:attention, :question}
  defp state(%{"pendingRuntimeRequest" => %{}}), do: {:attention, :approval}
  defp state(%{"status" => "failed"}), do: {:attention, :failed}
  defp state(%{"hasActionableProposedPlan" => true}), do: {:attention, :plan}
  defp state(%{"activeRunId" => run}) when run != nil, do: {:working, nil}
  defp state(_thread), do: {:open, nil}

  defp datetime(value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    datetime
  end

  defp segment(id), do: URI.encode(id, &URI.char_unreserved?/1)

  defp publish(servers),
    do: Phoenix.PubSub.broadcast(WaveDashboard.PubSub, @topic, {:agents, sorted(servers)})
end
