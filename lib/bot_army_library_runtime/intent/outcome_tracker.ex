defmodule BotArmyLibraryRuntime.Intent.OutcomeTracker do
  @moduledoc """
  Captures intent lifecycle events from NATS and persists outcome records.

  Subscribes to `events.bot_army.intent.>` and records every intent decision
  (proposed, acted, vetoed, deferred, aborted). When the eventual outcome is
  known, call `resolve/3` to update the record with success/failure metadata.

  ThresholdModel and ReflectionJob query outcome data to adapt intent weights.

  ## Lifecycle

  1. Intent proposed → OutcomeTracker records initial decision
  2. Intent acted/vetoed/deferred/aborted → updates decision field
  3. Bot calls `resolve(intent_id, :success/:failure, metadata)` when outcome is known
  4. ReflectionJob scans outcomes periodically and writes weight adjustments

  ## Configuration

      config :bot_army_library_runtime, :outcome_tracker,
        subscribe_subject: "events.bot_army.intent.>"
  """

  use GenServer

  require Logger

  alias BotArmyLibraryRuntime.IntentOutcome

  @subscribe_subject "events.bot_army.intent.>"

  # ───────────────────────────────────────────────────────────────────────────
  # Client API
  # ───────────────────────────────────────────────────────────────────────────

  @doc """
  Start the OutcomeTracker GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Resolve an outcome for a previously recorded intent.

  Updates the intent_outcomes row matching `intent_id` with the given outcome
  and metadata. Returns `{:ok, record}`, `:not_found`, or `:skipped`.
  """
  @spec resolve(String.t(), atom(), map()) ::
          {:ok, map()} | {:error, term()} | :not_found | :skipped
  def resolve(intent_id, outcome, metadata \\ %{}) when is_binary(intent_id) do
    outcome_str = atom_to_outcome(outcome)
    IntentOutcome.resolve(intent_id, outcome_str, metadata)
  end

  @doc """
  Get recent outcomes for a bot+action pair.
  """
  @spec recent_outcomes(String.t(), String.t(), keyword()) :: [map()]
  def recent_outcomes(bot_name, action, opts \\ []) do
    IntentOutcome.recent_outcomes(bot_name, action, opts)
  end

  @doc """
  Get success rate for a bot+action over a time window.
  """
  @spec success_rate(String.t(), String.t(), keyword()) :: float()
  def success_rate(bot_name, action, opts \\ []) do
    IntentOutcome.success_rate(bot_name, action, opts)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # GenServer Callbacks
  # ───────────────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    subject = Keyword.get(opts, :subscribe_subject, @subscribe_subject)

    state = %{
      subscribe_subject: subject,
      subscription_ref: nil,
      pending: %{}
    }

    # Register for NATS connection status so we can re-subscribe on reconnect
    BotArmyLibraryRuntime.NATS.Connection.subscribe_to_status()

    case subscribe_to_nats(subject) do
      {:ok, ref} ->
        Logger.info("[OutcomeTracker] Subscribed to #{subject}")
        {:ok, %{state | subscription_ref: ref}}

      {:error, reason} ->
        Logger.warning(
          "[OutcomeTracker] NATS subscription failed: #{inspect(reason)}, will retry on reconnect"
        )

        {:ok, state}
    end
  end

  @impl true
  def handle_info({:gnat, :msg, %{subject: subject, body: body}}, state) do
    case Jason.decode(body) do
      {:ok, event} ->
        handle_intent_event(subject, event, state)

      {:error, _reason} ->
        Logger.debug("[OutcomeTracker] Failed to decode event on #{subject}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("[OutcomeTracker] NATS connected, re-subscribing")
    ref = resubscribe(state)
    {:noreply, %{state | subscription_ref: ref}}
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("[OutcomeTracker] NATS disconnected, clearing subscription")
    {:noreply, %{state | subscription_ref: nil}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Event Handling
  # ───────────────────────────────────────────────────────────────────────────

  defp handle_intent_event(subject, event, state) do
    payload = Map.get(event, "payload", %{})

    bot_name = Map.get(payload, "bot_name")
    action = Map.get(payload, "action")
    intent_id = Map.get(payload, "intent_id")

    if is_binary(bot_name) and is_binary(action) and is_binary(intent_id) do
      record_from_event(subject, bot_name, action, intent_id, payload, state)
    else
      Logger.debug("[OutcomeTracker] Skipping event with missing fields on #{subject}")
      {:noreply, state}
    end
  end

  defp record_from_event(subject, bot_name, action, intent_id, payload, state) do
    decision = extract_decision(subject, payload)
    score = Map.get(payload, "score")
    reason = Map.get(payload, "reason") || extract_reason(subject)

    outcome = if decision == "vetoed", do: "failure", else: nil

    attrs = %{
      bot_name: bot_name,
      action: action,
      intent_id: intent_id,
      decision: decision,
      outcome: outcome,
      outcome_metadata: %{},
      score: if(is_number(score), do: score * 1.0, else: nil),
      reason: reason,
      observed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    case IntentOutcome.record(attrs) do
      {:ok, _record} ->
        new_pending =
          Map.put(state.pending, intent_id, %{
            bot_name: bot_name,
            action: action,
            decision: decision
          })

        {:noreply, %{state | pending: new_pending}}

      :skipped ->
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("[OutcomeTracker] Failed to record outcome: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  defp extract_decision(subject, payload) do
    cond do
      String.contains?(subject, ".acted") -> "act"
      String.contains?(subject, ".vetoed") -> "vetoed"
      String.contains?(subject, ".deferred") -> "defer"
      String.contains?(subject, ".aborted") -> "abort"
      String.contains?(subject, ".proposed") -> "proposed"
      true -> Map.get(payload, "decision", "unknown")
    end
  end

  defp extract_reason(subject) do
    cond do
      String.contains?(subject, ".acted") -> "threshold_met"
      String.contains?(subject, ".vetoed") -> "vetoed"
      String.contains?(subject, ".deferred") -> "below_threshold"
      String.contains?(subject, ".aborted") -> "below_threshold"
      String.contains?(subject, ".proposed") -> "proposed"
      true -> "unknown"
    end
  end

  defp atom_to_outcome(outcome) when is_atom(outcome) do
    case outcome do
      :success -> "success"
      :failure -> "failure"
      :partial -> "partial"
      :unknown -> "unknown"
      other -> Atom.to_string(other)
    end
  end

  defp atom_to_outcome(outcome) when is_binary(outcome), do: outcome

  # ───────────────────────────────────────────────────────────────────────────
  # NATS Subscription
  # ───────────────────────────────────────────────────────────────────────────

  defp subscribe_to_nats(subject) do
    cond do
      Process.whereis(BotArmyLibraryRuntime.NATS.Connection) == nil ->
        {:error, :nats_not_connected}

      Process.whereis(:gnat) == nil ->
        {:error, :gnat_not_ready}

      true ->
        case Gnat.sub(:gnat, self(), subject) do
          {:ok, ref} -> {:ok, ref}
          {:error, reason} -> {:error, reason}
        end
    end
  rescue
    _ -> {:error, :nats_not_available}
  end

  defp resubscribe(state) do
    case subscribe_to_nats(state.subscribe_subject) do
      {:ok, ref} ->
        Logger.info("[OutcomeTracker] Re-subscribed to #{state.subscribe_subject}")
        ref

      {:error, reason} ->
        Logger.warning("[OutcomeTracker] Re-subscription failed: #{inspect(reason)}")
        nil
    end
  end
end
