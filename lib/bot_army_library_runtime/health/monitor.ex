defmodule BotArmyLibraryRuntime.Health.Monitor do
  @moduledoc """
  Monitors bot heartbeats and publishes alerts when bots go stale.

  Subscribes to `bot.army.health.>`, tracks last-seen timestamps
  in ETS, and checks every 30s for entries older than 60s. Stale bots
  get an alert published to `bot.army.health.stale`; recovery events
  go to `bot.army.health.recovered`.

  Public ETS reads via `get_status/1`, `list_bots/0`, `list_stale/0`
  don't require GenServer calls.

  ## Alerts are not heartbeats

  `bot.army.health.stale` / `bot.army.health.recovered` live in the *same*
  namespace as heartbeats, so reading "last subject segment = bot id" turned
  every alert into a heartbeat for a phantom bot literally named `"stale"` or
  `"recovered"`. That phantom then went silent, got alerted on, came back,
  got alerted on again ... a self-sustaining loop (2026-09-20: 4 tavern
  narrations per minute, forever, plus ~22k decoder-rejection log lines
  fleet-wide). Alert subjects are classified as alerts and never tracked.
  """

  use GenServer

  require Logger

  @table :bot_army_health_monitor
  @alert_claims :bot_army_health_alert_claims
  @stale_threshold_ms 60_000
  @check_interval_ms 30_000
  @reconnect_delay_ms 5_000

  @alert_events ["bot.army.health.stale", "bot.army.health.recovered"]

  # Bot ids that can only come from this module's own alert vocabulary.
  # Rows with these names are phantoms left behind by the old self-consumption
  # bug; purge them and never track them again.
  @phantom_bot_ids ["stale", "recovered"]

  # Internal services that publish health separately from their parent bot
  # (e.g. goal_store is part of Synapse, not a standalone service).
  @ignored_bot_ids ["goal_store"]

  # Every bot runs a monitor, and every monitor alerts on its own, so one real
  # flap used to publish one alert per bot in the fleet (terrain: ~25 identical
  # `recovered` alerts inside the same second). Jitter the publish, then skip it
  # if a peer already claimed that (event, bot) transition on the wire.
  @alert_publish_jitter_ms 2_000
  @alert_claim_ttl_ms 10_000

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

    if :ets.whereis(@alert_claims) == :undefined do
      :ets.new(@alert_claims, [:named_table, :set, :public, read_concurrency: true])
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
          BotArmyLibraryRuntime.NATS.Connection.subscribe_to_status()
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
    payload = parse_body(body)

    case classify(subject, payload) do
      {:alert, event, bot_id} ->
        claim_alert(event, bot_id)
        {:noreply, state}

      {:heartbeat, bot_id} ->
        track_heartbeat(bot_id, payload)
        {:noreply, state}

      :ignore ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:publish_alert, event, payload}, state) do
    maybe_publish_alert(event, payload)
    {:noreply, state}
  end

  @impl true
  def handle_info(:check, state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - @stale_threshold_ms

    purge_phantom_bots()

    stale_entries =
      :ets.tab2list(@table)
      |> Enum.filter(fn {_bot_id, last_seen_at, status, _payload} ->
        status == :healthy and last_seen_at < cutoff
      end)

    for {bot_id, last_seen_at, _status, _payload} <- stale_entries do
      stale_for_sec = div(now - last_seen_at, 1000)
      :ets.insert(@table, {bot_id, last_seen_at, :stale, nil})

      Logger.warning("[Health.Monitor] Bot stale: #{bot_id} (silent #{stale_for_sec}s)")

      schedule_alert("bot.army.health.stale", %{
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

      try do
        case BotArmyLibraryRuntime.NATS.Conversation.Gossip.maybe_gossip(gossip_bot, idle: true) do
          {:gossip_sent, partner} ->
            Logger.info("[Health.Monitor] #{gossip_bot} gossiped with #{partner}")

          _ ->
            :ok
        end
      rescue
        UndefinedFunctionError ->
          # Conversation system not available in this bot; skip gossip
          :ok

        _ ->
          # Other errors in gossip; log but don't crash the monitor
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
    try do
      case Process.whereis(BotArmyLibraryRuntime.NATS.Connection) do
        nil ->
          {:error, :no_connection_manager}

        _ ->
          GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 1000)
      end
    rescue
      _ -> {:error, :no_connection_manager}
    end
  end

  # Classifies an incoming `bot.army.health.>` message: `{:alert, event, bot_id}`
  # for this module's own alert vocabulary, `{:heartbeat, bot_id}` for a real bot
  # heartbeat, or `:ignore`. Alerts must never be treated as heartbeats — see the
  # moduledoc for the loop that caused.
  @doc false
  def classify(subject, payload \\ %{}) do
    cond do
      alert_event?(subject) ->
        {:alert, subject, alert_bot_id(payload)}

      alert_payload?(payload) ->
        {:alert, payload["event"], alert_bot_id(payload)}

      bot_id = heartbeat_bot_id(subject) ->
        {:heartbeat, bot_id}

      true ->
        :ignore
    end
  end

  @doc false
  def alert_event?(subject), do: subject in @alert_events

  @doc false
  def alert_payload?(payload) when is_map(payload) do
    Map.has_key?(payload, "stale_for_sec") or Map.has_key?(payload, "recovered_at")
  end

  def alert_payload?(_payload), do: false

  @doc false
  def heartbeat_bot_id("bot.army.health." <> bot_id)
      when bot_id not in @ignored_bot_ids and bot_id not in @phantom_bot_ids,
      do: bot_id

  def heartbeat_bot_id(_subject), do: nil

  defp alert_bot_id(payload) when is_map(payload), do: Map.get(payload, "bot_id", "unknown")
  defp alert_bot_id(_payload), do: "unknown"

  @doc false
  def claim_alert(event, bot_id) do
    :ets.insert(@alert_claims, {{event, bot_id}, System.monotonic_time(:millisecond)})
    :ok
  end

  @doc false
  def alert_claimed?(event, bot_id) do
    case :ets.lookup(@alert_claims, {event, bot_id}) do
      [{_key, at}] -> System.monotonic_time(:millisecond) - at < @alert_claim_ttl_ms
      [] -> false
    end
  end

  defp schedule_alert(event, payload) do
    delay = :rand.uniform(@alert_publish_jitter_ms)
    Process.send_after(self(), {:publish_alert, event, payload}, delay)
  end

  defp maybe_publish_alert(event, payload) do
    bot_id = Map.get(payload, :bot_id)

    if alert_claimed?(event, bot_id) do
      Logger.debug(
        "[Health.Monitor] #{event} for #{bot_id} already published by a peer; skipping"
      )
    else
      publish(event, payload)
    end
  end

  defp track_heartbeat(bot_id, payload) do
    now = System.monotonic_time(:millisecond)
    was_stale = was_stale?(bot_id)

    :ets.insert(@table, {bot_id, now, :healthy, payload})

    if was_stale do
      Logger.info("[Health.Monitor] Bot recovered: #{bot_id}")

      schedule_alert("bot.army.health.recovered", %{
        bot_id: bot_id,
        recovered_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })
    end
  end

  defp purge_phantom_bots do
    for bot_id <- @phantom_bot_ids do
      case :ets.lookup(@table, bot_id) do
        [] ->
          :ok

        [row] ->
          :ets.delete(@table, bot_id)

          Logger.info(
            "[Health.Monitor] purged phantom health entry: #{bot_id} #{inspect(elem(row, 2))}"
          )
      end
    end
  end

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
    BotArmyLibraryRuntime.NATS.Publisher.publish(subject, envelope)
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

        case Gnat.request(conn, subject, "{}", receive_timeout: 2000) do
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
