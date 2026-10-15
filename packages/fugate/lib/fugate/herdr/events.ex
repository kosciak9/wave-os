defmodule Fugate.Herdr.Events do
  @moduledoc """
  Holds the Herdr `events.subscribe` stream and forwards agent events to the
  scheduler. Every (re)connect and every `lagged` notice asks the scheduler to
  reconcile, because Herdr does not replay events missed while disconnected.
  """
  use GenServer
  require Logger

  @subscriptions [%{type: "pane.turn_completed"}, %{type: "pane.agent_status_changed"}]
  # Herdr writes a heartbeat after 15 quiet seconds.
  @silence_timeout 45_000
  @max_backoff 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    {:ok, %{socket: nil, buffer: "", backoff: 1_000, watchdog: nil}, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl true
  def handle_info(:connect, state), do: {:noreply, connect(state)}

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    :inet.setopts(socket, active: :once)
    {lines, buffer} = split_lines(state.buffer <> data)
    state = %{state | buffer: buffer} |> reset_watchdog()

    Enum.reduce_while(lines, {:noreply, state}, fn line, {:noreply, state} ->
      handle_line(line, state)
    end)
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state),
    do: {:noreply, disconnect(state, :closed)}

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state),
    do: {:noreply, disconnect(state, reason)}

  def handle_info(:silence, %{socket: socket} = state) when socket != nil,
    do: {:noreply, disconnect(state, :silence)}

  def handle_info(_stale, state), do: {:noreply, state}

  defp connect(state) do
    request = %{
      id: "fugate-events",
      method: "events.subscribe",
      params: %{events_v2: true, subscriptions: @subscriptions}
    }

    with {:ok, socket} <- Fugate.Herdr.connect(),
         :ok <- :gen_tcp.send(socket, JSON.encode!(request) <> "\n") do
      :inet.setopts(socket, active: :once)
      reset_watchdog(%{state | socket: socket, buffer: ""})
    else
      error ->
        Logger.warning("Herdr events connection failed: #{inspect(error)}")
        retry(state)
    end
  end

  defp handle_line(line, state) do
    case JSON.decode(line) do
      {:ok, %{"result" => %{"type" => "subscription_started"}}} ->
        Logger.info("Herdr events subscribed")
        Fugate.Scheduler.herdr_connected()
        {:cont, {:noreply, %{state | backoff: 1_000}}}

      {:ok, %{"control" => "lagged"} = lagged} ->
        Logger.warning("Herdr events lagged: #{inspect(lagged)}")
        Fugate.Scheduler.herdr_connected()
        {:cont, {:noreply, state}}

      {:ok, %{"control" => "heartbeat"}} ->
        {:cont, {:noreply, state}}

      {:ok, %{"error" => error}} ->
        {:halt, {:noreply, disconnect(state, error)}}

      {:ok, %{"event" => event, "data" => data}} ->
        Fugate.Scheduler.herdr_event(event, data)
        {:cont, {:noreply, state}}

      other ->
        Logger.warning("Ignoring Herdr event line: #{inspect(other)}")
        {:cont, {:noreply, state}}
    end
  end

  defp disconnect(state, reason) do
    Logger.warning("Herdr events disconnected: #{inspect(reason)}")
    :gen_tcp.close(state.socket)
    Fugate.Scheduler.herdr_disconnected()
    retry(%{state | socket: nil, buffer: ""})
  end

  defp retry(state) do
    cancel_watchdog(state)
    Process.send_after(self(), :connect, state.backoff)
    %{state | watchdog: nil, backoff: min(state.backoff * 2, @max_backoff)}
  end

  defp reset_watchdog(state) do
    cancel_watchdog(state)
    %{state | watchdog: Process.send_after(self(), :silence, @silence_timeout)}
  end

  defp cancel_watchdog(%{watchdog: nil}), do: :ok
  defp cancel_watchdog(%{watchdog: ref}), do: Process.cancel_timer(ref)

  defp split_lines(buffer) do
    [rest | lines] = buffer |> String.split("\n") |> Enum.reverse()
    {Enum.reverse(lines), rest}
  end
end
