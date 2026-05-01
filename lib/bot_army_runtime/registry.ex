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
  @registry_presence_subject "bot_army.registry.presence"

  # ───────────────────────────────────────────────────────────────────────────
  # Capability API
  # ───────────────────────────────────────────────────────────────────────────

  @doc """
  Find bots that provide a given capability.

  Returns `{:ok, [bot_names]}` or `{:ok, []}` if none found.
  """
  def find_by_capability(capability_name) when is_binary(capability_name) do
    GenServer.call(__MODULE__, {:find_by_capability, capability_name}, 5000)
  end

  @doc """
  List all registered capabilities and which bots provide them.

  Returns `{:ok, %{capability => [bot_names]}}`
  """
  def list_capabilities do
    GenServer.call(__MODULE__, :list_capabilities, 5000)
  end

  @doc """
  Find the best bot to handle a given intent.

  Uses capability matching, falling back to subject name matching.
  Returns `{:ok, bot_name}` or `{:error, :no_provider}`.
  """
  def find_target_for_intent(intent) when is_binary(intent) do
    GenServer.call(__MODULE__, {:find_target_for_intent, intent}, 5000)
  end

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
    GenServer.cast(__MODULE__, {:register, bot_name, subjects, nil})
  end

  def register(bot_name, subjects, version)
      when is_binary(bot_name) and is_list(subjects) do
    GenServer.cast(__MODULE__, {:register, bot_name, subjects, version})
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
      capabilities: %{},
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
            "bot_army.registry.subject.providers.get",
            "bot_army.registry.capabilities.list",
            "conv.registry.capabilities.find",
            "conv.registry.conversation.target",
            @registry_presence_subject
          ]
          |> Enum.map(fn subject ->
            subscribe_opts =
              if subject == @registry_presence_subject do
                []
              else
                [queue_group: @registry_queue_group]
              end

            case Gnat.sub(conn, self(), subject, subscribe_opts) do
              {:ok, sub} ->
                Logger.info("[Registry] Subscribed to #{subject}#{queue_group_suffix(subject)}")

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
    if msg.topic == @registry_presence_subject do
      handle_presence_message(msg, state)
    else
      handle_nats_query(msg, state)
    end
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
  def handle_cast({:register, bot_name, subjects, version}, state) do
    now_unix_ms = System.system_time(:millisecond)
    resolved_version = version || "unknown"
    state = upsert_bot_entry(state, bot_name, subjects, resolved_version, now_unix_ms)
    entry = Map.fetch!(state.bots, bot_name)

    broadcast_presence(state, bot_name, entry.subjects, resolved_version, now_unix_ms)

    Logger.info(
      "[Registry] Bot registered: #{bot_name} v#{resolved_version} with #{length(entry.subjects)} subjects"
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast({:deregister, bot_name}, state) do
    updated_bots = Map.delete(state.bots, bot_name)

    # Rebuild capability index
    capabilities = build_capability_index(%{state | bots: updated_bots})

    Logger.info("[Registry] Bot deregistered: #{bot_name}")
    {:noreply, %{state | bots: updated_bots, capabilities: capabilities}}
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

  @impl true
  def handle_call({:find_by_capability, capability_name}, _from, state) do
    bots =
      state.capabilities
      |> Map.get(capability_name, [])
      |> Enum.sort()

    {:reply, {:ok, bots}, state}
  end

  @impl true
  def handle_call(:list_capabilities, _from, state) do
    {:reply, {:ok, state.capabilities}, state}
  end

  @impl true
  def handle_call({:find_target_for_intent, intent}, _from, state) do
    # First try direct capability match
    capability_key = intent_to_capability(intent)

    result =
      case Map.get(state.capabilities, capability_key) do
        [bot_name | _] ->
          {:ok, bot_name}

        _ ->
          # Fall back to subject name matching
          state.bots
          |> Map.values()
          |> Enum.find_value(fn entry ->
            matching_subject =
              Enum.find(entry.subjects, fn s ->
                String.contains?(s.subject, intent) or
                  String.contains?(s.subject, intent_to_subject_pattern(intent))
              end)

            if matching_subject, do: {:ok, entry.name}, else: nil
          end)
      end

    {:reply, result || {:error, :no_provider}, state}
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

        "bot_army.registry.capabilities.list" ->
          handle_capabilities_list_query(state)

        "conv.registry.capabilities.find" ->
          handle_capabilities_find_query(body, state)

        "conv.registry.conversation.target" ->
          handle_conversation_target_query(body, state)

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

  defp handle_presence_message(%{body: body}, state) do
    case Jason.decode(body) do
      {:ok, %{"bot_name" => bot_name, "subjects" => subjects} = payload}
      when is_binary(bot_name) and is_list(subjects) ->
        version = Map.get(payload, "version", "unknown")
        heartbeat_at = Map.get(payload, "heartbeat_at", System.system_time(:millisecond))
        {:noreply, upsert_bot_entry(state, bot_name, subjects, version, heartbeat_at)}

      {:ok, _} ->
        {:noreply, state}

      {:error, reason} ->
        Logger.debug("[Registry] Ignoring invalid presence payload: #{inspect(reason)}")
        {:noreply, state}
    end
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
      "version" => Map.get(entry, :version, "unknown"),
      "registered_at" =>
        entry.registered_at |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601(),
      "last_heartbeat" =>
        entry.last_heartbeat_at |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601(),
      "subject_count" => length(entry.subjects),
      "subjects" => Enum.map(entry.subjects, &format_subject/1)
    }
  end

  defp format_subject(subject) do
    base = %{
      "subject" => subject.subject,
      "type" => Atom.to_string(subject.type),
      "description" => Map.get(subject, :description, ""),
      "timeout_ms" => Map.get(subject, :timeout_ms, 5000)
    }

    base =
      if Map.get(subject, :capabilities) do
        Map.put(base, "capabilities", subject.capabilities)
      else
        base
      end

    if Map.get(subject, :conversation_support) do
      Map.put(base, "conversation_support", subject.conversation_support)
    else
      base
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Capability Index
  # ───────────────────────────────────────────────────────────────────────────

  defp build_capability_index(state) do
    state.bots
    |> Map.values()
    |> Enum.reduce(%{}, fn bot_entry, acc ->
      bot_caps =
        bot_entry.subjects
        |> Enum.flat_map(fn subject ->
          Map.get(subject, :capabilities, [])
        end)

      Enum.reduce(bot_caps, acc, fn cap, inner_acc ->
        Map.update(inner_acc, cap, [bot_entry.name], &(&1 ++ [bot_entry.name]))
      end)
    end)
  end

  defp handle_capabilities_find_query(body, state) do
    try do
      case Jason.decode(body) do
        {:ok, params} ->
          capability = params["capability"]

          if is_nil(capability) do
            BotArmyRuntime.NATS.Reply.error(
              "capability parameter required",
              :missing_parameter
            )
          else
            bots = Map.get(state.capabilities, capability, [])

            BotArmyRuntime.NATS.Reply.ok(%{
              "capability" => capability,
              "providers" => Enum.sort(bots),
              "count" => length(bots)
            })
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

  defp handle_conversation_target_query(body, state) do
    try do
      case Jason.decode(body) do
        {:ok, params} ->
          intent = params["intent"]

          if is_nil(intent) do
            BotArmyRuntime.NATS.Reply.error("intent parameter required", :missing_parameter)
          else
            capability_key = intent_to_capability(intent)

            target =
              case Map.get(state.capabilities, capability_key) do
                [bot_name | _] ->
                  %{"bot_name" => bot_name, "matched_by" => "capability"}

                _ ->
                  # Fall back to subject matching
                  state.bots
                  |> Map.values()
                  |> Enum.find_value(fn entry ->
                    matching =
                      Enum.find(entry.subjects, fn s ->
                        String.contains?(s.subject, intent) or
                          String.contains?(s.subject, intent_to_subject_pattern(intent))
                      end)

                    if matching,
                      do: %{
                        "bot_name" => entry.name,
                        "matched_by" => "subject",
                        "subject" => matching.subject
                      },
                      else: nil
                  end)
              end

            if target do
              BotArmyRuntime.NATS.Reply.ok(target)
            else
              BotArmyRuntime.NATS.Reply.error(
                "No provider found for intent: #{intent}",
                :no_provider
              )
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

  defp handle_capabilities_list_query(state) do
    caps =
      state.capabilities
      |> Enum.map(fn {capability, bot_names} ->
        %{
          "capability" => capability,
          "provider_count" => length(bot_names),
          "providers" => Enum.sort(bot_names)
        }
      end)
      |> Enum.sort_by(& &1["capability"])

    BotArmyRuntime.NATS.Reply.ok(%{
      "capabilities" => caps,
      "count" => length(caps),
      "responder" => responder_identity()
    })
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Intent mapping
  # ───────────────────────────────────────────────────────────────────────────

  @intent_mappings %{
    "get_task_count" => "task.query",
    "count_tasks" => "task.query",
    "list_tasks" => "task.query",
    "find_task" => "task.query",
    "search_tasks" => "task.query",
    "create_task" => "task.create",
    "add_task" => "task.create",
    "update_task" => "task.update",
    "complete_task" => "task.complete",
    "delete_task" => "task.delete",
    "defer_task" => "task.defer",
    "add_inbox_item" => "inbox.add",
    "create_project" => "project.create",
    "update_project" => "project.update",
    "list_projects" => "project.list",
    "summarize_text" => "llm.summarize",
    "summarize" => "llm.summarize",
    "classify_text" => "llm.classify",
    "classify" => "llm.classify",
    "ask_llm" => "llm.ask",
    "ask" => "llm.ask",
    "complete_prompt" => "llm.complete",
    "generate_embedding" => "llm.embed",
    "index_document" => "llm.rag.index",
    "search_documents" => "llm.rag.search",
    "analyze_image" => "llm.vision.analyze"
  }

  defp intent_to_capability(intent) do
    Map.get(@intent_mappings, intent, intent)
  end

  defp intent_to_subject_pattern(intent) do
    case intent_to_capability(intent) do
      "task." <> _ -> "task"
      "project." <> _ -> "project"
      "inbox." <> _ -> "inbox"
      "llm." <> _ -> "llm"
      other -> other
    end
  end

  defp filter_bots(bots, nil), do: bots

  defp filter_bots(bots, filter) when is_map(filter) do
    min_health = Map.get(filter, "min_health", 0.0)
    status_filter = Map.get(filter, "status")
    subjects_filter = Map.get(filter, "subjects")

    bots
    |> Enum.filter(fn bot ->
      health_score = Map.get(bot, :health_score, Map.get(bot, "health_score", 1.0))
      bot_status = Map.get(bot, :status, Map.get(bot, "health_status", "healthy"))

      health_ok = health_score >= min_health

      status_ok =
        case status_filter do
          nil -> true
          sf when is_binary(sf) -> bot_status == sf
          sf when is_list(sf) -> bot_status in sf
          _ -> true
        end

      subjects_ok =
        case subjects_filter do
          nil ->
            true

          sf when is_list(sf) ->
            bot_subjects = Map.get(bot, :subjects, []) |> Enum.map(& &1.subject)
            Enum.any?(sf, fn s -> s in bot_subjects end)

          _ ->
            true
        end

      health_ok and status_ok and subjects_ok
    end)
  end

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

  defp queue_group_suffix(subject) do
    if subject == @registry_presence_subject,
      do: "",
      else: " (queue_group=#{@registry_queue_group})"
  end

  # Presence payloads and some callers decode subjects as string-key maps; normalize
  # once at the storage boundary so list/format paths can assume atom keys.
  defp normalize_subject_record(subject) when is_map(subject) do
    subject_name = Map.get(subject, :subject) || Map.get(subject, "subject")
    type_raw = Map.get(subject, :type) || Map.get(subject, "type")
    description = Map.get(subject, :description) || Map.get(subject, "description") || ""
    timeout_ms = Map.get(subject, :timeout_ms) || Map.get(subject, "timeout_ms") || 5000

    base = %{
      subject: subject_name,
      type: normalize_subject_type(type_raw),
      description: description,
      timeout_ms: timeout_ms
    }

    base =
      case Map.get(subject, :capabilities) || Map.get(subject, "capabilities") do
        nil -> base
        caps -> Map.put(base, :capabilities, caps)
      end

    case Map.get(subject, :conversation_support) || Map.get(subject, "conversation_support") do
      nil -> base
      cs -> Map.put(base, :conversation_support, cs)
    end
  end

  defp normalize_subject_type(t) when is_atom(t), do: t

  defp normalize_subject_type(t) when is_binary(t) do
    case t do
      "request_reply" ->
        :request_reply

      "pub_sub" ->
        :pub_sub

      "subscribe" ->
        :subscribe

      _ ->
        try do
          String.to_existing_atom(t)
        rescue
          ArgumentError -> :request_reply
        end
    end
  end

  defp normalize_subject_type(_), do: :request_reply

  defp upsert_bot_entry(state, bot_name, subjects, version, heartbeat_at_unix_ms) do
    now_monotonic = System.monotonic_time(:millisecond)
    existing_entry = Map.get(state.bots, bot_name)

    registered_at =
      if existing_entry, do: existing_entry.registered_at, else: heartbeat_at_unix_ms

    normalized_subjects = Enum.map(subjects, &normalize_subject_record/1)

    entry = %{
      name: bot_name,
      version: version || "unknown",
      subjects: normalized_subjects,
      last_heartbeat_monotonic_ms: now_monotonic,
      last_heartbeat_at: heartbeat_at_unix_ms,
      registered_at: registered_at
    }

    bots = Map.put(state.bots, bot_name, entry)
    capabilities = build_capability_index(%{state | bots: bots})
    %{state | bots: bots, capabilities: capabilities}
  end

  defp broadcast_presence(state, bot_name, subjects, version, heartbeat_at_unix_ms) do
    if state.connection do
      payload = %{
        "bot_name" => bot_name,
        "version" => version,
        "subjects" => Enum.map(subjects, &format_subject/1),
        "heartbeat_at" => heartbeat_at_unix_ms
      }

      case Jason.encode(payload) do
        {:ok, body} ->
          Gnat.pub(state.connection, @registry_presence_subject, body)

        {:error, reason} ->
          Logger.debug("[Registry] Failed to encode presence payload: #{inspect(reason)}")
      end
    end
  end
end
