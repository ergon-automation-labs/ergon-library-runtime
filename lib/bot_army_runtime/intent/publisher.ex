defmodule BotArmyRuntime.Intent.Publisher do
  @moduledoc """
  Publishes intent messages on `bot_army.<bot>.intent.<action>` subjects.

  The IntentPublisher is called from a bot's heartbeat cycle when the
  ThresholdModel decides the bot should act. It:

  1. Publishes an intent envelope on the intent subject
  2. Subscribes to veto/endorsement responses for a configurable window (default 2s)
  3. If no veto is received, returns `{:proceed, intent_id, endorsements}`
  4. If a veto is received, returns `{:vetoed, vetoing_bot, reason}`
  5. Endorsements are collected and returned — they don't block but signal
     support from other bots

  ## Usage

      alias BotArmyRuntime.Intent.Publisher

      case Publisher.publish_intent("gtd", "nudge", %{
        threshold_result: %{stale_count: 5, idle_minutes: 120, decision: :act},
        context_snapshot: %{last_activity: ~N[2026-05-03 10:00:00]},
        random_roll: %{notation: "1d20", total: 14}
      }) do
        {:proceed, intent_id, endorsements} ->
          # No veto — go ahead. endorsements lists who supported this.
          BotArmyGTD.Nudge.send(user_id, task_id)
          Logger.info("Endorsed by: \#{inspect(endorsements)}")

        {:vetoed, vetoing_bot, reason} ->
          Logger.info("Nudge vetoed by \#{vetoing_bot}: \#{reason}")

        {:error, reason} ->
          Logger.error("Intent publish failed: \#{inspect(reason)}")
      end

  ## Veto Protocol

  Other bots subscribe to `bot_army.<bot>.intent.>` and can publish a veto
  response on `bot_army.<bot>.intent.<action>.response`:

      %{
        "veto" => true,
        "reason" => "user is in a focus session",
        "vetoing_bot" => "fitness",
        "correlation_id" => intent_correlation_id
      }

  Or an endorsement:

      %{
        "endorsement" => true,
        "endorsing_bot" => "synapse",
        "correlation_id" => intent_correlation_id
      }

  ## Configuration

      config :bot_army_library_runtime, :intent,
        veto_timeout_ms: 2_000,
        veto_queue_group: "intent_veto",
        enabled: true
  """

  require Logger

  alias BotArmyRuntime.Intent.Schema
  alias BotArmyRuntime.NATS.Publisher

  @default_veto_timeout_ms 2_000

  @doc """
  Publish an intent and wait for potential vetoes.

  Returns `{:proceed, intent_id, endorsements}` if no veto within the window,
  `{:vetoed, vetoing_bot, reason}` if a veto arrives, or
  `{:error, reason}` on failure.

  Endorsements is a list of `{endorsing_bot, correlation_id}` tuples from
  bots that signaled support during the window.

  Options:
    - `:veto_timeout_ms` — override default veto window (default 2000ms)
    - `:skip_veto` — skip veto window entirely, just publish and proceed
    - `:context_snapshot` — map of accumulated context at decision time
    - `:threshold_result` — map from ThresholdModel evaluation
    - `:random_roll` — map from bridge.random.roll result
  """
  @spec publish_intent(String.t(), String.t(), map(), keyword()) ::
          {:proceed, String.t(), [{String.t(), String.t()}]}
          | {:vetoed, String.t(), String.t()}
          | {:error, term()}
  def publish_intent(bot_name, action, metadata \\ %{}, opts \\ []) do
    unless enabled?(), do: {:error, :disabled}

    intent_id = UUID.uuid4()
    correlation_id = ensure_correlation_id()

    subject = Schema.intent_subject(bot_name, action)
    veto_subj = Schema.veto_subject(bot_name, action)

    envelope =
      build_envelope(intent_id, bot_name, action, subject, correlation_id, metadata, opts)

    case Publisher.publish(subject, envelope) do
      {:ok, _} ->
        Logger.info("[Intent] Published #{subject}",
          intent_id: intent_id,
          bot_id: bot_name,
          action: action,
          correlation_id: correlation_id
        )

        publish_proposed_event(bot_name, action, intent_id, envelope, correlation_id)

        if Keyword.get(opts, :skip_veto, false) do
          {:proceed, intent_id, []}
        else
          wait_for_vetoes(intent_id, veto_subj, opts)
        end

      {:error, reason} ->
        Logger.error("[Intent] Failed to publish #{subject}",
          intent_id: intent_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  @doc """
  Publish a veto response to an intent.

  Called by a bot that wants to block an intent from proceeding.
  """
  @spec publish_veto(String.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def publish_veto(bot_name, action, vetoing_bot, reason, correlation_id) do
    veto_subj = Schema.veto_subject(bot_name, action)

    payload = %{
      veto: true,
      reason: reason,
      vetoing_bot: vetoing_bot,
      correlation_id: correlation_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case Publisher.publish(veto_subj, payload) do
      {:ok, subject} ->
        Logger.info("[Intent] Veto sent from #{vetoing_bot} to #{bot_name}.#{action}",
          correlation_id: correlation_id
        )

        {:ok, subject}

      {:error, reason} ->
        Logger.error("[Intent] Veto publish failed",
          reason: inspect(reason),
          correlation_id: correlation_id
        )

        {:error, reason}
    end
  end

  @doc """
  Publish an intent endorsement (non-blocking, signals support).

  A bot can endorse an intent to signal support. Endorsements are collected
  by the publisher and returned to the acting bot, allowing it to weigh
  support vs. silence when deciding how to act.
  """
  @spec publish_endorsement(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def publish_endorsement(bot_name, action, endorsing_bot, correlation_id) do
    endorse_subj = Schema.veto_subject(bot_name, action)

    payload = %{
      endorsement: true,
      endorsing_bot: endorsing_bot,
      correlation_id: correlation_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    Publisher.publish(endorse_subj, payload)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Events
  # ───────────────────────────────────────────────────────────────────────────

  defp publish_proposed_event(bot_name, action, intent_id, envelope, correlation_id) do
    event = %{
      "event_id" => UUID.uuid4(),
      "event" => "events.bot_army.intent.proposed",
      "schema_version" => "1.0",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_runtime",
      "source_node" => Atom.to_string(node()),
      "payload" => %{
        "bot_name" => bot_name,
        "action" => action,
        "intent_id" => intent_id,
        "correlation_id" => correlation_id,
        "score" => Map.get(envelope, :threshold_result, %{}) |> Map.get(:score, 0),
        "reason" => Map.get(envelope, :decision, "act"),
        "proposed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }

    Task.start(fn ->
      Publisher.publish("events.bot_army.intent.proposed", event)
    end)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Private
  # ───────────────────────────────────────────────────────────────────────────

  defp build_envelope(intent_id, bot_name, action, subject, correlation_id, metadata, opts) do
    %{
      intent_id: intent_id,
      bot_id: bot_name,
      action: action,
      subject: subject,
      context_snapshot:
        Keyword.get(opts, :context_snapshot, Map.get(metadata, :context_snapshot, %{})),
      threshold_result:
        Keyword.get(opts, :threshold_result, Map.get(metadata, :threshold_result, %{})),
      random_roll: Keyword.get(opts, :random_roll, Map.get(metadata, :random_roll, %{})),
      decision: Map.get(metadata, :decision, "act"),
      correlation_id: correlation_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp wait_for_vetoes(intent_id, veto_subj, opts) do
    timeout = Keyword.get(opts, :veto_timeout_ms, veto_timeout_ms())

    case get_connection() do
      {:ok, conn} ->
        :ok = Gnat.sub(conn, self(), veto_subj)

        {result, endorsements} =
          collect_responses(intent_id, veto_subj, conn, timeout, [])

        Gnat.unsub(conn, veto_subj)

        case result do
          :vetoed ->
            result

          :proceed ->
            {:proceed, intent_id, endorsements}
        end

      {:error, reason} ->
        Logger.warning(
          "[Intent] No NATS connection for veto window, proceeding without veto check",
          intent_id: intent_id,
          reason: inspect(reason)
        )

        {:proceed, intent_id, []}
    end
  end

  defp collect_responses(intent_id, veto_subj, conn, remaining_ms, endorsements) do
    start_time = System.monotonic_time(:millisecond)

    receive do
      {:msg, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, %{"veto" => true, "vetoing_bot" => vetoing_bot, "reason" => reason}} ->
            Logger.info("[Intent] Vetoed by #{vetoing_bot}",
              intent_id: intent_id,
              reason: reason
            )

            {{:vetoed, vetoing_bot, reason}, endorsements}

          {:ok, %{"endorsement" => true, "endorsing_bot" => endorsing_bot}} ->
            correlation_id = Map.get(Jason.decode!(body), "correlation_id", "")
            new_endorsements = [{endorsing_bot, correlation_id} | endorsements]
            elapsed = System.monotonic_time(:millisecond) - start_time
            remaining = max(0, remaining_ms - elapsed)
            collect_responses(intent_id, veto_subj, conn, remaining, new_endorsements)
        end
    after
      remaining_ms ->
        Logger.debug("[Intent] Veto window closed",
          intent_id: intent_id,
          endorsements: length(endorsements)
        )

        {{:proceed, intent_id, endorsements}, endorsements}
    end
  end

  defp veto_timeout_ms do
    config = Application.get_env(:bot_army_library_runtime, :intent, [])
    Keyword.get(config, :veto_timeout_ms, @default_veto_timeout_ms)
  end

  defp enabled? do
    config = Application.get_env(:bot_army_library_runtime, :intent, [])
    Keyword.get(config, :enabled, true)
  end

  defp ensure_correlation_id do
    case BotArmyRuntime.Correlation.current() do
      nil -> BotArmyRuntime.Correlation.generate()
      existing -> existing
    end
  end

  defp get_connection do
    timeout_ms = Application.get_env(:bot_army_library_runtime, :nats_connection_timeout, 1000)

    BotArmyRuntime.NATS.Connection
    |> GenServer.call(:get_connection, timeout_ms)
  rescue
    _e -> {:error, :no_connection_manager}
  end
end
