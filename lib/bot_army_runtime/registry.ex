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
  - `bot_army.registry.subjects.list` - List all known subjects and provider counts
  - `bot_army.registry.subject.providers.get` - Get providers for a specific subject

  Detects offline bots via periodic heartbeat checks and cleans up stale entries.
  """

  use GenServer
  require Logger

  @heartbeat_interval_ms 30_000
  @heartbeat_timeout_ms 5_000
  @stale_threshold_ms 40_000
  @registry_queue_group "bot_army.registry.query.responders"

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

  @doc """
  List all known subjects across registered bots.
  Returns: {:ok, [subject_entries]}
  """
  def list_subjects(filter \\ nil) do
    GenServer.call(__MODULE__, {:list_subjects, filter})
  end

  @doc """
  Get all providers for a subject.
  Returns: {:ok, subject_entry} or {:error, :not_found}
  """
  def get_subject_providers(subject) when is_binary(subject) do
    GenServer.call(__MODULE__, {:get_subject_providers, subject})
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
            "bot_army.registry.bot.get",
            "bot_army.registry.subjects.list",
            "bot_army.registry.subject.providers.get"
          ]
          |> Enum.map(fn subject ->
            case Gnat.sub(conn, self(), subject, queue_group: @registry_queue_group) do
              {:ok, sub} ->
                Logger.info(
                  "[Registry] Subscribed to #{subject} (queue_group=#{@registry_queue_group})"
                )

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
        stale? = entry.last_heartbeat_monotonic_ms < threshold

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
    now_monotonic = System.monotonic_time(:millisecond)
    now_unix_ms = System.system_time(:millisecond)
    existing_entry = Map.get(state.bots, bot_name)
    registered_at = if existing_entry, do: existing_entry.registered_at, else: now_unix_ms

    entry = %{
      name: bot_name,
      subjects: subjects,
      last_heartbeat_monotonic_ms: now_monotonic,
      last_heartbeat_at: now_unix_ms,
      registered_at: registered_at
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

  @impl true
  def handle_call({:list_subjects, _filter}, _from, state) do
    subjects =
      state.bots
      |> subject_index()
      |> Enum.map(fn {subject, providers} ->
        format_subject_discovery(subject, providers)
      end)
      |> Enum.sort_by(& &1["subject"])

    {:reply, {:ok, subjects}, state}
  end

  @impl true
  def handle_call({:get_subject_providers, subject}, _from, state) do
    providers = state.bots |> subject_index() |> Map.get(subject, [])

    case providers do
      [] ->
        {:reply, {:error, :not_found}, state}

      _ ->
        {:reply, {:ok, format_subject_discovery(subject, providers)}, state}
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

        "bot_army.registry.subjects.list" ->
          handle_subjects_list_query(state)

        "bot_army.registry.subject.providers.get" ->
          handle_subject_providers_query(body, state)

        _ ->
          BotArmyRuntime.NATS.Reply.error("Unknown registry subject: #{topic}", :unknown_subject)
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

    BotArmyRuntime.NATS.Reply.ok(%{
      "bots" => bots,
      "count" => length(bots),
      "responder" => responder_identity()
    })
  end

  defp handle_bot_get_query(body, state) do
    try do
      case Jason.decode(body) do
        {:ok, params} ->
          bot_name = params["bot_name"] || params["name"]

          if is_nil(bot_name) do
            BotArmyRuntime.NATS.Reply.error(
              "bot_name or name parameter required",
              :missing_parameter
            )
          else
            case Map.get(state.bots, bot_name) do
              nil ->
                BotArmyRuntime.NATS.Reply.error("Bot not found: #{bot_name}", :not_found)

              entry ->
                BotArmyRuntime.NATS.Reply.ok(%{
                  "bot" => format_bot_entry(entry),
                  "responder" => responder_identity()
                })
            end
          end

        {:error, _reason} ->
          BotArmyRuntime.NATS.Reply.error("Invalid JSON in request body", :invalid_request)
      end
    rescue
      e ->
        BotArmyRuntime.NATS.Reply.error(
          "Error processing request: #{inspect(e)}",
          :processing_error
        )
    end
  end

  defp handle_subjects_list_query(state) do
    subjects =
      state.bots
      |> subject_index()
      |> Enum.map(fn {subject, providers} ->
        format_subject_discovery(subject, providers)
      end)
      |> Enum.sort_by(& &1["subject"])

    BotArmyRuntime.NATS.Reply.ok(%{
      "subjects" => subjects,
      "count" => length(subjects),
      "responder" => responder_identity()
    })
  end

  defp handle_subject_providers_query(body, state) do
    try do
      case Jason.decode(body) do
        {:ok, params} ->
          subject = params["subject"]

          if is_nil(subject) do
            BotArmyRuntime.NATS.Reply.error("subject parameter required", :missing_parameter)
          else
            providers = state.bots |> subject_index() |> Map.get(subject, [])

            case providers do
              [] ->
                BotArmyRuntime.NATS.Reply.error("Subject not found: #{subject}", :not_found)

              _ ->
                discovery = format_subject_discovery(subject, providers)

                BotArmyRuntime.NATS.Reply.ok(%{
                  "subject" => discovery,
                  "responder" => responder_identity()
                })
            end
          end

        {:error, _reason} ->
          BotArmyRuntime.NATS.Reply.error("Invalid JSON in request body", :invalid_request)
      end
    rescue
      e ->
        BotArmyRuntime.NATS.Reply.error(
          "Error processing request: #{inspect(e)}",
          :processing_error
        )
    end
  end

  defp format_bot_entry(entry) do
    %{
      "name" => entry.name,
      "registered_at" =>
        entry.registered_at |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601(),
      "last_heartbeat" =>
        entry.last_heartbeat_at |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601(),
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

  defp subject_index(bots_map) do
    bots_map
    |> Map.values()
    |> Enum.reduce(%{}, fn bot_entry, acc ->
      Enum.reduce(bot_entry.subjects, acc, fn subject, subject_acc ->
        provider = %{
          "bot_name" => bot_entry.name,
          "type" => Atom.to_string(subject.type),
          "description" => Map.get(subject, :description, ""),
          "timeout_ms" => Map.get(subject, :timeout_ms, 5000)
        }

        Map.update(subject_acc, subject.subject, [provider], &[provider | &1])
      end)
    end)
  end

  defp format_subject_discovery(subject, providers) do
    %{
      "subject" => subject,
      "provider_count" => length(providers),
      "providers" => Enum.sort_by(providers, & &1["bot_name"])
    }
  end

  defp responder_identity do
    %{
      "node" => node() |> Atom.to_string(),
      "pid" => self() |> inspect()
    }
  end
end
