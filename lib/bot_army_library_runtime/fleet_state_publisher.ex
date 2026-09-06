defmodule BotArmyLibraryRuntime.FleetStatePublisher do
  @moduledoc """
  Publishes bot state updates to NATS for fleet visibility.

  Used by bots at startup and periodically to announce their state.
  The bridge fleet_state_listener subscribes to these heartbeats.

  Usage:
    defmodule MyBot.Supervisor do
      def start_link(opts) do
        children = [
          {BotArmyLibraryRuntime.FleetStatePublisher,
            [app_name: :my_bot_app, interval_ms: 60_000]}
        ]
        Supervisor.start_link(children, opts)
      end
    end
  """

  use GenServer
  require Logger

  alias BotArmyLibraryRuntime.NATS.Connection
  alias BotArmyLibraryRuntime.NATS.Publisher

  @default_interval_ms 60_000
  @reconnect_delay_ms 5_000

  def start_link(opts \\ []) do
    app_name = Keyword.fetch!(opts, :app_name)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)

    GenServer.start_link(__MODULE__, {app_name, interval_ms}, name: __MODULE__)
  end

  @impl true
  def init({app_name, interval_ms}) do
    state = %{
      app_name: app_name,
      interval_ms: interval_ms,
      conn: nil,
      timer: nil,
      reconnect_attempt: 0
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case GenServer.call(Connection, :get_connection, 5_000) do
      {:ok, conn} ->
        Logger.info("[FleetStatePublisher] Connected for #{state.app_name}")
        # Publish immediately on connect
        publish_state(state.app_name, conn)
        # Schedule periodic publishes
        timer = Process.send_after(self(), :publish, state.interval_ms)
        {:noreply, %{state | conn: conn, timer: timer, reconnect_attempt: 0}}

      {:error, reason} ->
        Logger.warning("[FleetStatePublisher] Connection failed: #{inspect(reason)}, retrying...")
        Process.send_after(self(), :reconnect, @reconnect_delay_ms)
        {:noreply, %{state | reconnect_attempt: state.reconnect_attempt + 1}}
    end
  end

  @impl true
  def handle_info(:publish, state) do
    if state.conn do
      publish_state(state.app_name, state.conn)
      timer = Process.send_after(self(), :publish, state.interval_ms)
      {:noreply, %{state | timer: timer}}
    else
      {:noreply, state, {:continue, :connect}}
    end
  end

  @impl true
  def handle_info(:reconnect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @doc """
  Manually publish state right now (useful for testing).
  """
  def publish_now do
    GenServer.call(__MODULE__, :publish_now, 5_000)
  end

  @impl true
  def handle_call(:publish_now, _from, state) do
    if state.conn do
      publish_state(state.app_name, state.conn)
      {:reply, :ok, state}
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  defp publish_state(app_name, _conn) do
    payload = build_state_payload(app_name)
    subject = "bot_army.#{app_name}.state"

    # Publisher fetches its own connection (runtime >= 0.14: publish(subject, payload))
    # and returns {:ok, subject} | {:error, reason} — not bare :ok.
    case Publisher.publish(subject, payload) do
      {:ok, _} ->
        Logger.debug("[FleetStatePublisher] Published state for #{app_name}")

      {:error, reason} ->
        Logger.warning("[FleetStatePublisher] Failed to publish state: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.error("[FleetStatePublisher] Exception publishing state: #{inspect(e)}")
  end

  defp build_state_payload(app_name) do
    %{
      "name" => to_string(app_name),
      "version" => get_version(),
      "pid" => System.pid(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
    |> Jason.encode!()
  end

  defp get_version do
    case Application.spec(:bot_army_library_runtime, :vsn) do
      nil -> "unknown"
      vsn when is_list(vsn) -> List.to_string(vsn)
      vsn -> to_string(vsn)
    end
  end
end
