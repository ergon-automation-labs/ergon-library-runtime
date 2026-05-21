defmodule BotArmyRuntime.NATS.Conversation.Gossip do
  @moduledoc """
  Gossip/icebreaker engine for bot-to-bot conversation.

  Called from heartbeat cycles, the gossip engine randomly selects
  a conversation partner and sends a casual message via the mailbox
  or conversation protocol.

  ## Configuration

      config :bot_army_runtime, :gossip,
        enabled: true,
        probability_per_cycle: 0.05,   # 5% chance per heartbeat
        only_when_idle: true,          # Skip if bot has pending work
        max_active_gossips: 3          # Max concurrent gossip conversations

  ## Integration

  Call `Gossip.maybe_gossip/2` from your heartbeat cycle:

      BotArmyRuntime.NATS.Conversation.Gossip.maybe_gossip("gtd", %{idle: true, metric: "processed 150 events"})
  """

  require Logger

  alias BotArmyRuntime.Personality.Voice
  alias BotArmyRuntime.Registry
  alias Manager
  alias Mailbox

  @intents [
    :check_in,
    :share_metric,
    :ask_help,
    :celebrate,
    :nice_to_meet_you
  ]

  @doc """
  Called from heartbeat cycles. Randomly decides whether to send a gossip message.

  Returns `:skipped`, `:no_partner`, or `{:gossip_sent, bot_name}`.

  ## Options
    - `:force` — Force gossip regardless of probability (for testing)
    - `:idle` — Whether the bot is idle (default: true)
    - `:metric` — Optional metric string to personalize the message
    - `:mode` — `:mailbox` (default, async) or `:conversation` (expects response)
  """
  def maybe_gossip(bot_name, opts \\ []) do
    unless enabled?() do
      :skipped
    end

    # Check if we should skip due to activity
    if Keyword.get(opts, :idle, true) == false and only_when_idle?() and
         not Keyword.get(opts, :force, false) do
      :skipped
    end

    # Check active gossip count
    if Keyword.get(opts, :force, false) or roll_chance() do
      do_gossip(bot_name, opts)
    else
      :skipped
    end
  end

  @doc """
  Force-send a gossip message from a bot. Useful for testing or manual triggers.
  """
  def gossip_now(bot_name, opts \\ []) do
    do_gossip(bot_name, Keyword.put(opts, :force, true))
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Private
  # ───────────────────────────────────────────────────────────────────────────

  defp do_gossip(bot_name, opts) do
    case find_gossip_partner(bot_name) do
      nil ->
        Logger.debug("[Gossip] No partner found for #{bot_name}")
        :no_partner

      partner ->
        intent = select_intent()
        mode = Keyword.get(opts, :mode, :conversation)
        metric = Keyword.get(opts, :metric)
        count = Keyword.get(opts, :count, 0)

        message =
          Voice.gossip(bot_name, intent,
            count: count,
            metric: metric || count
          )

        template = %{
          intent: "gossip.#{intent}",
          subject: to_string(intent),
          message: message
        }

        case mode do
          :conversation ->
            start_gossip_conversation(bot_name, partner, template, message)

          :mailbox ->
            send_gossip_mailbox(bot_name, partner, template, message)
        end

        {:gossip_sent, partner}
    end
  end

  defp find_gossip_partner(bot_name) do
    case Registry.list_bots() do
      {:ok, bots} ->
        candidates =
          bots
          |> Enum.map(fn b -> b["name"] end)
          |> Enum.reject(fn name -> name == bot_name or is_nil(name) end)

        case candidates do
          [] -> nil
          _ -> Enum.random(candidates)
        end

      {:error, _reason} ->
        # Fallback: try known bots
        known = ["gtd", "llm", "synapse", "chore", "fitness"] -- [bot_name]

        case known do
          [] -> nil
          _ -> Enum.random(known)
        end
    end
  end

  defp select_intent do
    Enum.random(@intents)
  end

  defp start_gossip_conversation(from_bot, to_bot, template, message) do
    body = %{
      "intent" => template.intent,
      "subject" => template.subject,
      "message" => message
    }

    case Manager.start_conversation(
           from_bot,
           to_bot,
           "gossip",
           body,
           timeout_ms: 15_000,
           max_turns: 1
         ) do
      {:ok, conv_id} ->
        Logger.info("[Gossip] #{from_bot} started gossip with #{to_bot}: #{conv_id}")

      {:error, reason} ->
        Logger.debug("[Gossip] Failed to start gossip: #{inspect(reason)}")
    end
  end

  defp send_gossip_mailbox(from_bot, to_bot, template, message) do
    body = %{
      "intent" => template.intent,
      "subject" => template.subject,
      "message" => message
    }

    case Mailbox.send(
           from_bot,
           to_bot,
           "gossip",
           body
         ) do
      {:ok, _subject} ->
        Logger.info("[Gossip] #{from_bot} left gossip for #{to_bot}")

      {:error, reason} ->
        Logger.debug("[Gossip] Failed to send gossip: #{inspect(reason)}")
    end
  end

  defp roll_chance do
    prob = Application.get_env(:bot_army_runtime, :gossip, [])
    prob = Keyword.get(prob, :probability_per_cycle, 0.05)
    :rand.uniform() < prob
  end

  defp enabled? do
    config = Application.get_env(:bot_army_runtime, :gossip, [])
    Keyword.get(config, :enabled, true)
  end

  defp only_when_idle? do
    config = Application.get_env(:bot_army_runtime, :gossip, [])
    Keyword.get(config, :only_when_idle, true)
  end
end
