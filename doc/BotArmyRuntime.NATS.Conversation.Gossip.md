# `BotArmyRuntime.NATS.Conversation.Gossip`

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

# `gossip_now`

Force-send a gossip message from a bot. Useful for testing or manual triggers.

# `maybe_gossip`

Called from heartbeat cycles. Randomly decides whether to send a gossip message.

Returns `:skipped`, `:no_partner`, or `{:gossip_sent, bot_name}`.

## Options
  - `:force` — Force gossip regardless of probability (for testing)
  - `:idle` — Whether the bot is idle (default: true)
  - `:metric` — Optional metric string to personalize the message
  - `:mode` — `:mailbox` (default, async) or `:conversation` (expects response)

---

*Consult [api-reference.md](api-reference.md) for complete listing*
