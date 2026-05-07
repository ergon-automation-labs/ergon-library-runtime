defmodule BotArmyRuntime.Health.Monitor do
  @moduledoc """
  Monitors bot heartbeats and publishes alerts when bots go stale.

  Subscribes to `bot.army.health.>` on NATS, tracks last-seen timestamps
  in ETS, and checks every 30s for entries older than 60s. Stale bots
  get an alert published to `bot.army.health.stale`; recovery events
  go to `bot.army.health.recovered`.

  Public ETS reads via `get_status/1`, `list_bots/0`, `list_stale/0`
  don't require GenServer calls.
  """

  use GenServer

  require Logger

  @table :bot_army_health_monitor
  @stale_threshold_ms 60_000
  @check_interval_ms 30_000
  @reconnect_delay_ms 5_000

  def start_link(opts \\ []) do
    case GenServer.start_link(__MODULE__, opts, name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  # Public API (ETS reads, no GenServer call)

  @doc "Returns `{:ok, {last_seen_at, status}}` or `:unknown`."
  def get_status(bot_id) when is_binary(bot_id) do
    case :ets.lookup(@table, bot_id) do
      [{^bot_id, last_seen_at, status, _payload}] ->
        {:ok, {last_seen_at, status}}

      [] ->
        :unknown
    end
  end

  @doc "Lists all tracked bots as `[{bot_id, last_seen_at, status}]`."
  def list_bots do
    :ets.tab2list(@table)
    |> Enum.map(fn {bot_id, last_seen_at, status, _payload} ->
      {bot_id, last_seen_at, status}
    end)
  end

  @doc "Lists stale bots as `[{bot_id, last_seen_at, stale_for_sec}]`."
  def list_stale do
    now = System.monotonic_time(:millisecond)

    :ets.tab2list(@table)
    |> Enum.filter(fn {_bot_id, last_seen_at, status, _payload} ->
      status == :stale or now - last_seen_at > @stale_threshold_ms
    end)
    |> Enum.map(fn {bot_id, last_seen_at, _status, _payload} ->
      {bot_id, last_seen_at, div(now - last_seen_at, 1000)}
    end)
  end

  # GenServer

  @impl true
  def init(_opts) do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end

    state = %{
      connection: nil,
      subscription: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case get_nats_connection() do
      {:ok, conn} ->
        with {:ok, health_sub} <- Gnat.sub(conn, self(), "bot.army.health.>"),
             {:ok, subjects_sub} <- Gnat.sub(conn, self(), "bot.army.subjects") do
          BotArmyRuntime.NATS.Connection.subscribe_to_status()
          Logger.info("[Health.Monitor] Subscribed to bot.army.health.> and bot.army.subjects")
          schedule_check()
          {:noreply, %{state | connection: conn, subscription: {health_sub, subjects_sub}}}
        else
          {:error, reason} ->
            Logger.warning("[Health.Monitor] Subscription failed: #{inspect(reason)}")
            Process.send_after(self(), :reconnect, @reconnect_delay_ms)
            {:noreply, state}
        end

      {:error, reason} ->
        Logger.warning("[Health.Monitor] NATS not connected: #{inspect(reason)}")
        Process.send_after(self(), :reconnect, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:msg, %{topic: "bot.army.subjects", reply_to: reply_to}}, state)
      when not is_nil(reply_to) do
    subjects_by_bot = aggregate_subjects()

    response = %{
      "ok" => true,
      "data" => subjects_by_bot,
      "schema_version" => "1.0",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    payload = Jason.encode!(response)
    Gnat.pub(state.connection, reply_to, payload)
    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, %{topic: subject, body: body}}, state) do
    bot_id = extract_bot_id(subject)

    if bot_id do
      now = System.monotonic_time(:millisecond)
      payload = parse_body(body)
      was_stale = was_stale?(bot_id)

      :ets.insert(@table, {bot_id, now, :healthy, payload})

      if was_stale do
        Logger.info("[Health.Monitor] Bot recovered: #{bot_id}")

        publish("bot.army.health.recovered", %{
          bot_id: bot_id,
          recovered_at: DateTime.utc_now() |> DateTime.to_iso8601()
        })
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:check, state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - @stale_threshold_ms

    stale_entries =
      :ets.tab2list(@table)
      |> Enum.filter(fn {_bot_id, last_seen_at, status, _payload} ->
        status == :healthy and last_seen_at < cutoff
      end)

    for {bot_id, last_seen_at, _status, _payload} <- stale_entries do
      stale_for_sec = div(now - last_seen_at, 1000)
      :ets.insert(@table, {bot_id, last_seen_at, :stale, nil})

      Logger.warning("[Health.Monitor] Bot stale: #{bot_id} (silent #{stale_for_sec}s)")

      publish("bot.army.health.stale", %{
        bot_id: bot_id,
        last_seen_at: monotonic_to_iso(last_seen_at),
        stale_for_sec: stale_for_sec
      })
    end

    # Social gossip: pick one healthy bot and maybe gossip
    healthy_bots =
      :ets.tab2list(@table)
      |> Enum.filter(fn {_id, last_seen, status, _payload} ->
        status == :healthy and last_seen >= cutoff
      end)
      |> Enum.map(fn {bot_id, _last_seen, _status, _payload} -> bot_id end)

    if healthy_bots != [] do
      gossip_bot = Enum.random(healthy_bots)

      case BotArmyRuntime.NATS.Conversation.Gossip.maybe_gossip(gossip_bot, idle: true) do
        {:gossip_sent, partner} ->
          Logger.info("[Health.Monitor] #{gossip_bot} gossiped with #{partner}")

        _ ->
          :ok
      end
    end

    schedule_check()
    {:noreply, state}
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("[Health.Monitor] NATS disconnected, scheduling reconnect")
    Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    {:noreply, %{state | connection: nil, subscription: nil}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("[Health.Monitor] NATS reconnected, re-subscribing")
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Helpers

  defp get_nats_connection do
    GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 1000)
  rescue
    _ -> {:error, :no_connection_manager}
  end

  defp extract_bot_id("bot.army.health." <> bot_id), do: bot_id
  defp extract_bot_id(_), do: nil

  defp was_stale?(bot_id) do
    case :ets.lookup(@table, bot_id) do
      [{^bot_id, _last_seen_at, :stale, _payload}] -> true
      _ -> false
    end
  end

  defp parse_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{}
    end
  end

  defp parse_body(_), do: %{}

  defp publish(subject, payload) do
    envelope = build_envelope(subject, payload)
    BotArmyRuntime.NATS.Publisher.publish(subject, envelope)
  end

  defp build_envelope(event, payload) do
    %{
      "event_id" => UUID.uuid4(),
      "event" => event,
      "schema_version" => "1.0",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_runtime",
      "source_node" => node() |> Atom.to_string(),
      "triggered_by" => "health_monitor",
      "payload" => payload
    }
  end

  defp schedule_check do
    Process.send_after(self(), :check, @check_interval_ms)
  end

  defp monotonic_to_iso(monotonic_ms) do
    # Approximate: monotonic time offset from current time
    offset = System.monotonic_time(:millisecond) - monotonic_ms

    DateTime.utc_now()
    |> DateTime.add(-offset, :millisecond)
    |> DateTime.to_iso8601()
  end

  defp aggregate_subjects do
    # Query each known bot for its subjects via bot.<name>.subjects
    list_bots()
    |> Enum.map(fn {bot_id, _last_seen, _status} -> bot_id end)
    |> Enum.reduce(%{}, fn bot_id, acc ->
      case query_bot_subjects(bot_id) do
        {:ok, subjects} -> Map.put(acc, bot_id, subjects)
        {:error, _} -> acc
      end
    end)
  end

  defp query_bot_subjects(bot_id) do
    case get_nats_connection() do
      {:ok, conn} ->
        subject = "bot.#{bot_id}.subjects"

        case Gnat.request(conn, subject, "{}", timeout: 2000) do
          {:ok, %{body: body}} ->
            case Jason.decode(body) do
              {:ok, %{"data" => data}} -> {:ok, data}
              {:ok, resp} -> {:ok, resp}
              {:error, _} -> {:error, :decode}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
