defmodule WaveDashboard.Quota do
  @moduledoc false
  use GenServer

  @topic "quota"
  @interval :timer.seconds(30)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def subscribe, do: Phoenix.PubSub.subscribe(WaveDashboard.PubSub, @topic)
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @impl true
  def init(nil) do
    send(self(), :poll)
    {:ok, %{status: :loading, accounts: [], checked_at: nil, task: nil}}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, Map.drop(state, [:task]), state}

  @impl true
  def handle_info(:poll, state) do
    task = Task.Supervisor.async_nolink(WaveDashboard.TaskSupervisor, &fetch/0)
    {:noreply, %{state | task: task.ref}}
  end

  def handle_info({ref, result}, %{task: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: ref} = state),
    do: {:noreply, finish(state, {:error, :unavailable})}

  defp finish(state, result) do
    Process.send_after(self(), :poll, @interval)

    state =
      case result do
        {:ok, accounts} ->
          %{state | status: :ok, accounts: accounts, checked_at: DateTime.utc_now(), task: nil}

        {:error, reason} ->
          %{state | status: reason, task: nil}
      end

    Phoenix.PubSub.broadcast(WaveDashboard.PubSub, @topic, {:quota, Map.drop(state, [:task])})
    state
  end

  defp fetch do
    with {:ok, base} <- credential("quota-url"),
         {:ok, key} <- credential("quota-key"),
         %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}
         when is_binary(host) <- URI.parse(base),
         {:ok, {{_, 200, _}, _, body}} <-
           :httpc.request(
             :get,
             {String.to_charlist(String.trim_trailing(base, "/") <> "/v1/quota?schema=2"),
              [{~c"authorization", String.to_charlist("Bearer " <> key)}]},
             [
               timeout: 8_000,
               connect_timeout: 3_000,
               autoredirect: false,
               ssl: [
                 verify: :verify_peer,
                 cacerts: :public_key.cacerts_get(),
                 customize_hostname_check: [
                   match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
                 ]
               ]
             ],
             body_format: :binary
           ),
         {:ok, accounts} <- decode(body) do
      {:ok, accounts}
    else
      {:error, :not_configured} -> {:error, :not_configured}
      _ -> {:error, :unavailable}
    end
  end

  defp credential(name) do
    with directory when is_binary(directory) <-
           Application.get_env(:wave_dashboard, :credentials_directory),
         {:ok, value} <- File.read(Path.join(directory, name)),
         value = String.trim(value),
         true <- value != "" and not String.contains?(value, ["\r", "\n"]) do
      {:ok, value}
    else
      _ -> {:error, :not_configured}
    end
  end

  # Keep account names and emails out of the dashboard snapshot.
  def decode(body) do
    with {:ok, %{"schema" => 2, "accounts" => accounts}} when is_list(accounts) <-
           JSON.decode(body),
         true <- Enum.all?(accounts, &valid_account?/1) do
      accounts =
        accounts
        |> Enum.sort_by(& &1["id"])
        |> Enum.map_reduce(%{}, fn account, counts ->
          provider = account["provider"]
          count = Map.get(counts, provider, 0) + 1
          safe = Map.take(account, ["id", "provider", "status", "stale", "limits", "updated_at"])
          {Map.put(safe, "label", "#{provider} #{count}"), Map.put(counts, provider, count)}
        end)
        |> elem(0)
        |> Enum.sort_by(fn account ->
          limit = lowest(account)

          {if(account["status"] in ["cooldown", "error"], do: 0, else: 1),
           if(limit, do: limit["remaining_percent"], else: 101), account["label"]}
        end)

      {:ok, accounts}
    else
      _ -> {:error, :invalid_snapshot}
    end
  end

  defp valid_account?(%{
         "id" => id,
         "provider" => provider,
         "label" => label,
         "status" => status,
         "stale" => stale,
         "limits" => limits
       }) do
    Enum.all?([id, provider, label, status], &is_binary/1) and is_boolean(stale) and
      is_list(limits) and Enum.all?(limits, &valid_limit?/1)
  end

  defp valid_account?(_), do: false

  defp valid_limit?(%{"label" => label} = limit) do
    percent = limit["remaining_percent"]
    reset = limit["reset_at"]

    is_binary(label) and valid_pace?(limit["pace"]) and
      (is_nil(percent) or (is_number(percent) and percent >= 0 and percent <= 100)) and
      (is_nil(reset) or (is_integer(reset) and reset >= 0 and reset <= 253_402_300_799))
  end

  defp valid_limit?(_), do: false

  defp valid_pace?(nil), do: true

  defp valid_pace?(%{"state" => state} = pace) do
    expected = pace["expected_remaining_percent"]

    state in ["reserve", "on_pace", "deficit", "exhausted", "unknown"] and
      (is_nil(expected) or (is_number(expected) and expected >= 0 and expected <= 100))
  end

  defp valid_pace?(_), do: false

  def current?(account, limit, snapshot, now) do
    snapshot.status == :ok and not account["stale"] and account["status"] == "ok" and
      DateTime.diff(now, snapshot.checked_at) < 90 and
      (is_nil(limit["reset_at"]) or limit["reset_at"] == 0 or
         limit["reset_at"] > DateTime.to_unix(now))
  end

  def lowest(account) do
    account["limits"]
    |> Enum.filter(&is_number(&1["remaining_percent"]))
    |> Enum.min_by(& &1["remaining_percent"], fn -> nil end)
  end
end
