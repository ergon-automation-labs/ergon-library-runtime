defmodule BotArmyRuntime.NATS.Conversation.Manager do
  @moduledoc """
  Manages cross-bot conversations.

  Tracks active conversations, routes responses to callers, enforces timeouts,
  supports multi-turn dialogues, and publishes lifecycle events.

  ## Conversation Lifecycle

  1. `start_conversation/5` — Bot A asks Bot B a question
     - Publishes `conv.request.<bot>.<id>`
     - Subscribes to `conv.response.<id>`
     - Sets timeout
  2. Bot B replies via `reply/4`
     - Publishes `conv.response.<id>`
     - Manager delivers to caller
     - If `conversation_complete=true`, marks done
  3. Optionally: `followup/6` for multi-turn
  4. Timeout or completion cleans up state

  ## Event Publishing

  Every state transition publishes an `events.conversation.*` event.
  """

  use GenServer
  require Logger

  alias BotArmyRuntime.NATS.Conversation.Envelope
  alias BotArmyRuntime.Tracing
  alias BotArmyRuntime.Correlation
  alias BotArmyRuntime.NATS.Connection

  # ───────────────────────────────────────────────────────────────────────────
  # Public API
  # ───────────────────────────────────────────────────────────────────────────

  @doc """
  Start a new conversation with another bot.

  Returns `{:ok, conversation_id}` immediately. The response is delivered
  as a message to the calling process: `{:conv_reply, conversation_id, body}`

  ## Options
    - `:timeout_ms` — How long to wait before timing out (default: 30_000)
    - `:max_turns` — Maximum follow-up exchanges (default: 5)
    - `:tenant_id` — Tenant context
    - `:user_id` — User context
    - `:context` — Extra context merged into body.context
    - `:priority` — Message priority (default: "normal")
  """
  def start_conversation(from_bot, to_bot, message_type, body, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)
    max_turns = Keyword.get(opts, :max_turns, 5)

    GenServer.call(
      __MODULE__,
      {:start_conversation, from_bot, to_bot, message_type, body, timeout_ms, max_turns, opts},
      timeout_ms + 1000
    )
  end

  @doc """
  Reply to an ongoing conversation.

  Called by the responding bot's handler. Publishes the response on
  `conv.response.<conversation_id>` and marks the conversation as
  completed if `conversation_complete` is true in opts.

  ## Options
    - `:conversation_complete` — Whether this reply ends the conversation (default: true)
    - `:message_type` — Type of response (default: "result")
  """
  def reply(conversation_id, from_bot, body, opts \\ []) do
    GenServer.cast(__MODULE__, {:reply, conversation_id, from_bot, body, opts})
  end

  @doc """
  Send a follow-up turn in an ongoing conversation.
  """
  def followup(conversation_id, from_bot, to_bot, message_type, body, opts \\ []) do
    GenServer.cast(
      __MODULE__,
      {:followup, conversation_id, from_bot, to_bot, message_type, body, opts}
    )
  end

  @doc """
  Get conversation state by ID.
  """
  def get_conversation(conversation_id) do
    GenServer.call(__MODULE__, {:get_conversation, conversation_id}, 5000)
  end

  @doc """
  List active conversations, optionally filtered by status.
  """
  def list_active(filter \\ nil) do
    GenServer.call(__MODULE__, {:list_active, filter}, 5000)
  end

  @doc """
  Cancel a conversation.
  """
  def cancel(conversation_id, reason \\ :cancelled) do
    GenServer.cast(__MODULE__, {:cancel, conversation_id, reason})
  end

  # ───────────────────────────────────────────────────────────────────────────
  # GenServer Callbacks
  # ───────────────────────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("[ConvManager] Starting conversation manager")

    # ETS table for fast conversation lookups
    ets =
      :ets.new(:bot_army_conversations, [
        :set,
        :named_table,
        :protected,
        {:read_concurrency, true},
        {:write_concurrency, true}
      ])

    state = %{
      ets: ets,
      conn: nil,
      subscriptions: [],
      conn_monitor: nil
    }

    # Defer NATS setup
    Process.send_after(self(), :setup_nats, 100)

    {:ok, state}
  end

  @impl true
  def handle_info(:setup_nats, state) do
    case get_nats_connection() do
      {:ok, conn} ->
        {:ok, resp_sub} = Gnat.sub(conn, self(), "conv.response.>")
        {:ok, foll_sub} = Gnat.sub(conn, self(), "conv.followup.>")

        Logger.info("[ConvManager] Subscribed to conv.response.> and conv.followup.>")

        {:noreply, %{state | conn: conn, subscriptions: [resp_sub, foll_sub]}}

      {:error, reason} ->
        Logger.warning("[ConvManager] NATS unavailable, retrying: #{inspect(reason)}")
        Process.send_after(self(), :setup_nats, 1000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:msg, msg}, state) when is_map(msg) do
    handle_nats_message(msg, state)
  end

  @impl true
  def handle_info({:conv_timeout, conversation_id}, state) do
    case lookup_conversation(conversation_id) do
      %{status: :active} = conv ->
        send(conv.caller_pid, {:conv_timeout, conversation_id})
        update_conversation(conversation_id, :status, :timed_out)
        set_timestamp(conversation_id, :timed_out_at)

        publish_event("events.conversation.timed_out", conversation_id, conv, %{
          timeout_ms: conv.timeout_ms
        })

        Logger.warning("[ConvManager] Conversation #{conversation_id} timed out")

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # Find and clean up conversations owned by the crashed caller
    dead_convos =
      :ets.foldl(
        fn {id, conv}, acc ->
          if conv.monitor_ref == ref, do: [id | acc], else: acc
        end,
        [],
        state.ets
      )

    Enum.each(dead_convos, fn id ->
      conv = lookup_conversation(id)
      update_conversation(id, :status, :orphaned)
      set_timestamp(id, :cancelled_at)
      publish_event("events.conversation.error", id, conv, %{error: "caller_crashed"})
      Logger.warning("[ConvManager] Conversation #{id} orphaned (caller crashed)")
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)
    # 5 minutes
    threshold = now - 300_000

    :ets.foldl(
      fn {id, conv}, acc ->
        if conv.status in [:completed, :timed_out, :orphaned] and
             (conv.cancelled_at || conv.timed_out_at || 0) < threshold do
          :ets.delete(state.ets, id)
        end

        acc
      end,
      :ok,
      state.ets
    )

    Process.send_after(self(), :cleanup, 60_000)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("[ConvManager] NATS disconnected")
    {:noreply, %{state | conn: nil, subscriptions: []}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("[ConvManager] NATS reconnected")
    Process.send_after(self(), :setup_nats, 100)
    {:noreply, state}
  end

  # Handle timeout message struct from Gnat
  @impl true
  def handle_info(:timeout, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ───────────────────────────────────────────────────────────────────────────
  # GenServer Calls
  # ───────────────────────────────────────────────────────────────────────────

  @impl true
  def handle_call(
        {:start_conversation, from_bot, to_bot, message_type, body, timeout_ms, max_turns, opts},
        {caller_pid, _ref},
        state
      ) do
    case do_start_conversation(
           from_bot,
           to_bot,
           message_type,
           body,
           timeout_ms,
           max_turns,
           opts,
           caller_pid,
           state
         ) do
      {:ok, conversation_id, state} ->
        {:reply, {:ok, conversation_id}, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_conversation, conversation_id}, _from, state) do
    case lookup_conversation(conversation_id) do
      nil -> {:reply, {:error, :not_found}, state}
      conv -> {:reply, {:ok, format_conversation(conv)}, state}
    end
  end

  @impl true
  def handle_call({:list_active, filter}, _from, state) do
    convos =
      :ets.foldl(
        fn {_id, conv}, acc ->
          if filter_matches?(conv, filter) and conv.status in [:pending, :active] do
            [format_conversation(conv) | acc]
          else
            acc
          end
        end,
        [],
        state.ets
      )

    {:reply, {:ok, convos}, state}
  end

  # ───────────────────────────────────────────────────────────────────────────
  # GenServer Casts
  # ───────────────────────────────────────────────────────────────────────────

  @impl true
  def handle_cast({:reply, conversation_id, from_bot, body, opts}, state) do
    do_reply(conversation_id, from_bot, body, opts, state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:followup, conversation_id, from_bot, to_bot, message_type, body, opts}, state) do
    do_followup(conversation_id, from_bot, to_bot, message_type, body, opts, state)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:cancel, conversation_id, reason}, state) do
    case lookup_conversation(conversation_id) do
      nil ->
        :ok

      conv ->
        cancel_timer(conv)
        update_conversation(conversation_id, :status, :cancelled)
        set_timestamp(conversation_id, :cancelled_at)
        publish_event("events.conversation.error", conversation_id, conv, %{error: reason})
        send(conv.caller_pid, {:conv_cancelled, conversation_id, reason})
    end

    {:noreply, state}
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Private — Core Logic
  # ───────────────────────────────────────────────────────────────────────────

  defp do_start_conversation(
         from_bot,
         to_bot,
         message_type,
         body,
         timeout_ms,
         max_turns,
         opts,
         caller_pid,
         state
       ) do
    conversation_id = UUID.uuid4()
    caller_ref = Process.monitor(caller_pid)
    timer_ref = Process.send_after(self(), {:conv_timeout, conversation_id}, timeout_ms)
    now = System.monotonic_time(:millisecond)

    # Build and publish the request envelope
    envelope =
      Envelope.build_request(
        from_bot,
        to_bot,
        message_type,
        body,
        Keyword.merge(opts, conversation_id: conversation_id)
      )

    subject = "conv.request.#{to_bot}.#{conversation_id}"

    case publish_nats(state.conn, subject, envelope) do
      :ok ->
        # Store conversation state
        entry = %{
          conversation_id: conversation_id,
          from_bot: from_bot,
          to_bot: to_bot,
          status: :active,
          message_type: message_type,
          current_turn: 1,
          max_turns: max_turns,
          timeout_ms: timeout_ms,
          started_at: now,
          last_activity_at: now,
          timed_out_at: nil,
          cancelled_at: nil,
          caller_pid: caller_pid,
          caller_ref: caller_ref,
          timer_ref: timer_ref,
          turn_history: [
            %{
              turn: 1,
              from: from_bot,
              message_type: message_type,
              timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
            }
          ],
          metadata: %{
            tenant_id: Keyword.get(opts, :tenant_id, "default"),
            user_id: Keyword.get(opts, :user_id),
            priority: Keyword.get(opts, :priority, "normal")
          }
        }

        :ets.insert(state.ets, {conversation_id, entry})

        publish_event("events.conversation.started", conversation_id, entry, %{})

        Logger.info(
          "[ConvManager] Started conversation #{conversation_id}: #{from_bot} -> #{to_bot} [#{message_type}]"
        )

        # Schedule cleanup sweep if first conversation
        Process.send_after(self(), :cleanup, 60_000)

        {:ok, conversation_id, state}

      {:error, reason} ->
        Process.demonitor(caller_ref, [:flush])
        Process.cancel_timer(timer_ref)
        Logger.error("[ConvManager] Failed to publish request: #{inspect(reason)}")
        {:error, reason, state}
    end
  end

  defp do_reply(conversation_id, from_bot, body, opts, state) do
    case lookup_conversation(conversation_id) do
      nil ->
        Logger.warning("[ConvManager] Reply to unknown conversation #{conversation_id}")

      %{status: :active} = conv ->
        complete = Keyword.get(opts, :conversation_complete, true)
        message_type = Keyword.get(opts, :message_type, "result")
        turn_number = conv.current_turn + 1

        # Build reply using stored envelope context
        reply_envelope =
          Envelope.build_response(
            %{
              "payload" => %{
                "conversation_id" => conversation_id,
                "from_bot" => conv.from_bot,
                "turn_number" => conv.current_turn
              }
            },
            from_bot,
            body,
            Keyword.merge(opts, conversation_complete: complete, message_type: message_type)
          )

        subject = "conv.response.#{conversation_id}"

        case publish_nats(state.conn, subject, reply_envelope) do
          :ok ->
            # Cancel the timeout timer since we got a response
            cancel_timer(conv)

            new_status = if complete, do: :completed, else: :active

            # Update turn history
            updated_conv = %{
              conv
              | status: new_status,
                current_turn: turn_number,
                last_activity_at: System.monotonic_time(:millisecond),
                timer_ref: nil,
                turn_history:
                  conv.turn_history ++
                    [
                      %{
                        turn: turn_number,
                        from: from_bot,
                        message_type: message_type,
                        conversation_complete: complete,
                        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
                      }
                    ]
            }

            :ets.insert(state.ets, {conversation_id, updated_conv})

            # Deliver to caller
            send(conv.caller_pid, {:conv_reply, conversation_id, body})

            event =
              if complete,
                do: "events.conversation.completed",
                else: "events.conversation.replied"

            publish_event(event, conversation_id, updated_conv, %{turn_number: turn_number})

            Logger.info(
              "[ConvManager] Reply in #{conversation_id}: turn #{turn_number}, complete=#{complete}"
            )

          {:error, reason} ->
            Logger.error("[ConvManager] Failed to publish reply: #{inspect(reason)}")
        end

      conv ->
        Logger.warning(
          "[ConvManager] Reply to inactive conversation #{conversation_id}: #{conv.status}"
        )
    end
  end

  defp do_followup(conversation_id, from_bot, to_bot, message_type, body, opts, state) do
    case lookup_conversation(conversation_id) do
      nil ->
        Logger.warning("[ConvManager] Followup to unknown conversation #{conversation_id}")

      %{status: :active} = conv ->
        turn_number = conv.current_turn + 1

        if turn_number > conv.max_turns do
          Logger.warning(
            "[ConvManager] Followup rejected: max turns (#{conv.max_turns}) reached for #{conversation_id}"
          )

          publish_event("events.conversation.error", conversation_id, conv, %{
            error: "max_turns_exceeded"
          })

          send(conv.caller_pid, {:conv_error, conversation_id, :max_turns_exceeded})
        else
          followup_envelope =
            Envelope.build_followup(
              conversation_id,
              from_bot,
              to_bot,
              message_type,
              body,
              Keyword.merge(opts, turn_number: turn_number)
            )

          subject = "conv.followup.#{conversation_id}"

          case publish_nats(state.conn, subject, followup_envelope) do
            :ok ->
              updated_conv = %{
                conv
                | current_turn: turn_number,
                  last_activity_at: System.monotonic_time(:millisecond),
                  turn_history:
                    conv.turn_history ++
                      [
                        %{
                          turn: turn_number,
                          from: from_bot,
                          message_type: message_type,
                          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
                        }
                      ]
              }

              :ets.insert(state.ets, {conversation_id, updated_conv})

              publish_event("events.conversation.followup", conversation_id, updated_conv, %{
                turn_number: turn_number
              })

              Logger.info(
                "[ConvManager] Followup in #{conversation_id}: turn #{turn_number}/#{conv.max_turns}"
              )

            {:error, reason} ->
              Logger.error("[ConvManager] Failed to publish followup: #{inspect(reason)}")
          end
        end

      conv ->
        Logger.warning(
          "[ConvManager] Followup to inactive conversation #{conversation_id}: #{conv.status}"
        )
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Private — NATS helpers
  # ───────────────────────────────────────────────────────────────────────────

  defp handle_nats_message(msg, state) do
    topic = msg.topic

    cond do
      String.starts_with?(topic, "conv.response.") ->
        handle_response_message(msg, state)

      String.starts_with?(topic, "conv.followup.") ->
        handle_followup_message(msg, state)

      true ->
        Logger.debug("[ConvManager] Unknown conversation message on #{topic}")
        {:noreply, state}
    end
  end

  defp handle_response_message(msg, state) do
    conversation_id = extract_id_from_subject(msg.topic, "conv.response.")

    if conversation_id do
      case lookup_conversation(conversation_id) do
        %{status: :active} = conv ->
          # Decode and deliver to caller
          case Jason.decode(msg.body) do
            {:ok, decoded} ->
              body = extract_body_from_envelope(decoded)

              # Cancel timeout
              cancel_timer(conv)

              complete = get_conversation_complete(decoded)
              new_status = if complete, do: :completed, else: :active

              updated_conv = %{
                conv
                | status: new_status,
                  last_activity_at: System.monotonic_time(:millisecond),
                  timer_ref: nil,
                  turn_history:
                    conv.turn_history ++
                      [
                        %{
                          turn: conv.current_turn + 1,
                          from: conv.to_bot,
                          received: true,
                          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
                        }
                      ]
              }

              :ets.insert(state.ets, {conversation_id, updated_conv})
              send(conv.caller_pid, {:conv_reply, conversation_id, body})

              event =
                if complete,
                  do: "events.conversation.completed",
                  else: "events.conversation.replied"

              publish_event(event, conversation_id, updated_conv, %{})

            {:error, _} ->
              Logger.warning("[ConvManager] Failed to decode response for #{conversation_id}")
          end

        _ ->
          Logger.debug(
            "[ConvManager] Response for unknown/inactive conversation #{conversation_id}"
          )
      end
    end

    {:noreply, state}
  end

  defp handle_followup_message(msg, state) do
    conversation_id = extract_id_from_subject(msg.topic, "conv.followup.")

    if conversation_id do
      case lookup_conversation(conversation_id) do
        %{status: :active} = conv ->
          case Jason.decode(msg.body) do
            {:ok, decoded} ->
              body = extract_body_from_envelope(decoded)
              send(conv.caller_pid, {:conv_followup, conversation_id, body})

            {:error, _} ->
              Logger.warning("[ConvManager] Failed to decode followup for #{conversation_id}")
          end

        _ ->
          :ok
      end
    end

    {:noreply, state}
  end

  defp extract_id_from_subject(topic, prefix) do
    case String.split(topic, ".") do
      parts when length(parts) >= 2 ->
        parts |> Enum.drop(String.split(prefix, ".") |> length()) |> Enum.join(".")

      _ ->
        nil
    end
  end

  defp extract_body_from_envelope(envelope) do
    case envelope do
      %{"payload" => %{"body" => body}} -> body
      %{"data" => data} -> data
      %{"body" => body} -> body
      other -> other
    end
  end

  defp get_conversation_complete(envelope) do
    case envelope do
      %{"payload" => %{"conversation_complete" => complete}} -> complete
      %{"conversation_complete" => complete} -> complete
      _ -> true
    end
  end

  defp publish_nats(nil, _subject, _envelope) do
    Logger.warning("[ConvManager] No NATS connection, cannot publish")
    {:error, :no_connection}
  end

  defp publish_nats(conn, subject, envelope) do
    try do
      json = Jason.encode!(envelope)

      headers =
        []
        |> Tracing.inject_trace_context()
        |> Correlation.inject_into_headers()

      Gnat.pub(conn, subject, json, headers: headers)
      :ok
    rescue
      e ->
        Logger.error("[ConvManager] Failed to publish: #{inspect(e)}")
        {:error, Exception.message(e)}
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Private — State helpers
  # ───────────────────────────────────────────────────────────────────────────

  defp lookup_conversation(conversation_id) do
    case :ets.lookup(:bot_army_conversations, conversation_id) do
      [{^conversation_id, entry}] -> entry
      [] -> nil
    end
  end

  defp update_conversation(conversation_id, key, value) do
    case :ets.lookup(:bot_army_conversations, conversation_id) do
      [{^conversation_id, entry}] ->
        :ets.insert(:bot_army_conversations, {conversation_id, %{entry | key => value}})

      [] ->
        :ok
    end
  end

  defp set_timestamp(conversation_id, field) do
    update_conversation(conversation_id, field, System.monotonic_time(:millisecond))
  end

  defp cancel_timer(conv) do
    if conv.timer_ref, do: Process.cancel_timer(conv.timer_ref)
    :ok
  end

  defp format_conversation(conv) do
    %{
      conversation_id: conv.conversation_id,
      from_bot: conv.from_bot,
      to_bot: conv.to_bot,
      status: conv.status,
      message_type: conv.message_type,
      current_turn: conv.current_turn,
      max_turns: conv.max_turns,
      turn_count: length(conv.turn_history),
      metadata: conv.metadata
    }
  end

  defp filter_matches?(_conv, nil), do: true

  defp filter_matches?(conv, filter) when is_atom(filter) do
    conv.status == filter
  end

  defp filter_matches?(conv, filter) when is_binary(filter) do
    to_string(conv.status) == filter
  end

  defp filter_matches?(_conv, _filter), do: true

  # ───────────────────────────────────────────────────────────────────────────
  # Private — Event publishing
  # ───────────────────────────────────────────────────────────────────────────

  defp publish_event(subject, conversation_id, conv, extra) do
    payload = %{
      "conversation_id" => conversation_id,
      "from_bot" => conv.from_bot,
      "to_bot" => conv.to_bot,
      "message_type" => conv.message_type,
      "turn_number" => conv.current_turn,
      "status" => conv.status,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    payload = Map.merge(payload, extra)

    envelope = %{
      "event_id" => UUID.uuid4(),
      "event" => subject,
      "schema_version" => "1.0",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_runtime",
      "source_node" => Atom.to_string(node()),
      "triggered_by" => "bot_conversation",
      "tenant_id" => conv.metadata[:tenant_id] || "default",
      "payload" => payload
    }

    # Fire-and-forget event (best-effort)
    Task.start(fn ->
      case get_nats_connection() do
        {:ok, conn} ->
          try do
            Gnat.pub(conn, subject, Jason.encode!(envelope))
          rescue
            _ -> :ok
          end

        _ ->
          :ok
      end
    end)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Private — Connection
  # ───────────────────────────────────────────────────────────────────────────

  defp get_nats_connection do
    timeout_ms = Application.get_env(:bot_army_runtime, :nats_connection_timeout, 1000)

    case Process.whereis(Connection) do
      nil ->
        Logger.warning("[ConvManager] NATS connection process not started yet")
        {:error, :no_connection_manager}

      _ ->
        Connection
        |> GenServer.call(:get_connection, timeout_ms)
    end
  rescue
    _e -> {:error, :no_connection_manager}
  end
end
