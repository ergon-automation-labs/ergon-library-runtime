defmodule BotArmyRuntime.Registry do
  @moduledoc """
  In-memory service discovery registry for the Bot Army ecosystem.

  Maintains a registry of all active bots and their available NATS subjects,
  enabling service discovery and capability introspection.

  Bots register themselves on startup via `register/2`, providing:
  - Bot name
  - Version
  - List of subjects with metadata (type, description, timeout)

  The registry responds to NATS queries:
  - `bot_army.registry.bots.list` - List all registered bots
  - `bot_army.registry.bot.get` - Get details for a specific bot

  Detects offline bots via periodic heartbeat checks and cleans up stale entries.
  """

  use GenServer
  require Logger

  @heartbeat_interval_ms 30_000
  @heartbeat_timeout_ms 5_000
  @stale_threshold_ms 40_000

  # ============================================================================
  # Public API
  # ============================================================================

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Register a bot with its subjects.

  subjects should be a list of maps:
  ```
  [
    %{subject: "gtd.task.create", type: :request_reply, description: "Create task", timeout_ms: 5000},
    %{subject: "gtd.task.list", type: :request_reply, description: "List tasks", timeout_ms: 5000}
  ]
  ```
  """
  def register(bot_name, subjects) when is_binary(bot_name) and is_list(subjects) do
    GenServer.cast(__MODULE__, {:register, bot_name, subjects})
  end

  @doc """
  Deregister a bot from the registry.
  """
  def deregister(bot_name) when is_binary(bot_name) do
    GenServer.cast(__MODULE__, {:deregister, bot_name})
  end

  @doc """
  Get all registered bots.
  Returns: {:ok, [bot_entries]} or {:error, reason}
  """
  def list_bots(filter \\ nil) do
    GenServer.call(__MODULE__, {:list_bots, filter})
  end

  @doc """
  Get details for a specific bot.
  Returns: {:ok, bot_entry} or {:error, :not_found}
  """
  def get_bot(bot_name) when is_binary(bot_name) do
    GenServer.call(__MODULE__, {:get_bot, bot_name})
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    Logger.info("[Registry] Starting service discovery registry")

    # Subscribe to registry query endpoints
    Process.send_after(self(), :setup_nats, 100)
    Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)

    state = %{
      bots: %{},
      nats_subscriptions: [],
      connection: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:setup_nats, state) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, @heartbeat_timeout_ms) do
      {:ok, conn} ->
        Logger.info("[Registry] Connected to NATS, setting up query endpoints")

        subs =
          [
            "bot_army.registry.bots.list",
            "bot_army.registry.bot.get"
          ]
          |> Enum.map(fn subject ->
            case Gnat.sub(conn, self(), subject) do
              {:ok, sub} ->
                Logger.info("[Registry] Subscribed to #{subject}")
                sub

              {:error, reason} ->
                Logger.error("[Registry] Failed to subscribe to #{subject}: #{inspect(reason)}")
                nil
            end
          end)
          |> Enum.filter(&(not is_nil(&1)))

        {:noreply, %{state | connection: conn, nats_subscriptions: subs}}

      {:error, reason} ->
        Logger.warning("[Registry] NATS not ready, retrying in 1s: #{inspect(reason)}")
        Process.send_after(self(), :setup_nats, 1000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:heartbeat, state) do
    # Perform heartbeat checks to detect offline bots
    now = System.monotonic_time(:millisecond)
    threshold = now - @stale_threshold_ms

    cleaned_bots =
      state.bots
      |> Enum.reject(fn {_name, entry} ->
        stale? = entry.last_heartbeat < threshold

        if stale? do
          Logger.info("[Registry] Bot #{entry.name} offline (no heartbeat for 40s)")
        end

        stale?
      end)
      |> Enum.into(%{})

    # Schedule next heartbeat
    Process.send_after(self(), :heartbeat, @heartbeat_interval_ms)

    {:noreply, %{state | bots: cleaned_bots}}
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    handle_nats_query(msg, state)
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("[Registry] NATS disconnected")
    {:noreply, %{state | connection: nil, nats_subscriptions: []}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("[Registry] NATS reconnected, re-subscribing to endpoints")
    Process.send_after(self(), :setup_nats, 100)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:register, bot_name, subjects}, state) do
    now = System.monotonic_time(:millisecond)

    entry = %{
      name: bot_name,
      subjects: subjects,
      last_heartbeat: now,
      registered_at: now
    }

    Logger.info("[Registry] Bot registered: #{bot_name} with #{length(subjects)} subjects")

    {:noreply, %{state | bots: Map.put(state.bots, bot_name, entry)}}
  end

  @impl true
  def handle_cast({:deregister, bot_name}, state) do
    Logger.info("[Registry] Bot deregistered: #{bot_name}")
    {:noreply, %{state | bots: Map.delete(state.bots, bot_name)}}
  end

  @impl true
  def handle_call({:list_bots, filter}, _from, state) do
    bots =
      state.bots
      |> Map.values()
      |> Enum.map(&format_bot_entry/1)
      |> filter_bots(filter)

    {:reply, {:ok, bots}, state}
  end

  @impl true
  def handle_call({:get_bot, bot_name}, _from, state) do
    case Map.get(state.bots, bot_name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        {:reply, {:ok, format_bot_entry(entry)}, state}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp handle_nats_query(%{topic: topic, reply_to: reply_to, body: body}, state)
       when not is_nil(reply_to) do
    response =
      case topic do
        "bot_army.registry.bots.list" ->
          handle_bots_list_query(state)

        "bot_army.registry.bot.get" ->
          handle_bot_get_query(body, state)

        _ ->
          error_response("unknown_subject", "Unknown registry subject: #{topic}")
      end

    if state.connection do
      Gnat.pub(state.connection, reply_to, response)
    end

    {:noreply, state}
  end

  defp handle_nats_query(_msg, state) do
    {:noreply, state}
  end

  defp handle_bots_list_query(state) do
    bots = state.bots |> Map.values() |> Enum.map(&format_bot_entry/1)

    response = %{
      "ok" => true,
      "bots" => bots,
      "count" => length(bots),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    Jason.encode!(response)
  end

  defp handle_bot_get_query(body, state) do
    try do
      case Jason.decode(body) do
        {:ok, params} ->
          bot_name = params["bot_name"] || params["name"]

          if is_nil(bot_name) do
            error_response("missing_parameter", "bot_name or name parameter required")
          else
            case Map.get(state.bots, bot_name) do
              nil ->
                error_response("not_found", "Bot not found: #{bot_name}")

              entry ->
                response = %{
                  "ok" => true,
                  "bot" => format_bot_entry(entry),
                  "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
                }

                Jason.encode!(response)
            end
          end

        {:error, _reason} ->
          error_response("invalid_request", "Invalid JSON in request body")
      end
    rescue
      e ->
        error_response("error", "Error processing request: #{inspect(e)}")
    end
  end

  defp format_bot_entry(entry) do
    %{
      "name" => entry.name,
      "registered_at" =>
        DateTime.from_unix!(div(entry.registered_at, 1000)) |> DateTime.to_iso8601(),
      "last_heartbeat" =>
        DateTime.from_unix!(div(entry.last_heartbeat, 1000)) |> DateTime.to_iso8601(),
      "subject_count" => length(entry.subjects),
      "subjects" => Enum.map(entry.subjects, &format_subject/1)
    }
  end

  defp format_subject(subject) do
    %{
      "subject" => subject.subject,
      "type" => Atom.to_string(subject.type),
      "description" => Map.get(subject, :description, ""),
      "timeout_ms" => Map.get(subject, :timeout_ms, 5000)
    }
  end

  defp filter_bots(bots, nil), do: bots
  # TODO: Implement health-based filtering
  defp filter_bots(bots, _filter), do: bots

  defp error_response(error, description) do
    response = %{
      "ok" => false,
      "error" => error,
      "error_description" => description,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    Jason.encode!(response)
  end
end
