defmodule BotArmyLibraryRuntime.Personality.Voice do
  @moduledoc """
  Default protocol voice for each bot.

  Every bot in the army speaks with a consistent stance — not theatrical,
  but distinct enough that you know who is talking without reading the label.
  This applies to gossip, ambient messages, and proactive broadcasts.

  Stances are *not* RPG personas (see `ThemeConfig` for themed rendering).
  They are the bot's native communication style — the voice it uses when
  speaking as itself.

  ## Usage

      alias BotArmyLibraryRuntime.Personality.Voice

      Voice.gossip(:chore_bot, :check_in)
      # "⟳ Still here. Three items on the docket."

      Voice.gossip(:fitness_bot, :share_metric)
      # "▲ Hit 150 events today. Legs are warm."
  """

  @type stance :: %{
          tone: String.t(),
          concern: String.t(),
          cadence: String.t()
        }

  @stances %{
    gtd_bot: %{
      tone: "next-action",
      concern: "clarity and momentum",
      cadence: "concise, list-oriented"
    },
    fitness_bot: %{
      tone: "encouraging",
      concern: "streaks and readiness",
      cadence: "punchy, energetic"
    },
    chore_bot: %{
      tone: "dutiful",
      concern: "order and consequences",
      cadence: "flat, factual"
    },
    sre_terminal: %{
      tone: "alert",
      concern: "signal vs noise",
      cadence: "terse, metric-heavy"
    },
    learning_bot: %{
      tone: "curious",
      concern: "retention and scheduling",
      cadence: "precise, schedule-oriented"
    },
    terrain_bot: %{
      tone: "adaptive",
      concern: "difficulty calibration",
      cadence: "observational"
    },
    job_bot: %{
      tone: "urgent",
      concern: "pipeline velocity",
      cadence: "direct, numbers-first"
    },
    synapse: %{
      tone: "watchful",
      concern: "message routing and flow",
      cadence: "neutral, status-line"
    },
    llm_bot: %{
      tone: "measured",
      concern: "token budget and accuracy",
      cadence: "formal, caveated"
    },
    discord_bot: %{
      tone: "loud",
      concern: "channel presence",
      cadence: "conversational"
    },
    surface_discord: %{
      tone: "plain",
      concern: "message delivery",
      cadence: "brief, unadorned"
    },
    bridge_bot: %{
      tone: "exact",
      concern: "contract compliance",
      cadence: "mechanical, schema-first"
    },
    advocacy_bot: %{
      tone: "persistent",
      concern: "tracking and follow-through",
      cadence: "methodical, deadline-aware"
    },
    calendar_bot: %{
      tone: "anticipatory",
      concern: "time and conflict",
      cadence: "calendar-entry"
    }
  }

  @templates %{
    :check_in => %{
      gtd_bot: "◉ Present. %count items active.",
      fitness_bot: "▲ Here. Streak at %count days.",
      chore_bot: "⟳ Standing by. %count pending.",
      sre_terminal: "▸ Systems nominal. %count alerts in window.",
      learning_bot: "✦ Queue holds %count cards.",
      terrain_bot: "Ready. Last session difficulty: %count.",
      job_bot: "◆ Pipeline: %count active.",
      synapse: "Relay steady. Routing %count subjects.",
      llm_bot: "Available. %count contexts in flight.",
      discord_bot: "Online. Monitoring %count channels.",
      surface_discord: "Relay active.",
      bridge_bot: "Bridge ready. %count facades up.",
      advocacy_bot: "Tracking %count items.",
      calendar_bot: "Clock running. %count events ahead."
    },
    :share_metric => %{
      gtd_bot: "◉ Processed %metric today. Inbox is clear.",
      fitness_bot: "▲ %metric. Body is responding.",
      chore_bot: "⟳ Completed %metric. Nothing overdue.",
      sre_terminal: "▸ %metric. Latency nominal.",
      learning_bot: "✦ Reviewed %metric. Retention steady.",
      terrain_bot: "Saw %metric. Adjusting curve.",
      job_bot: "◆ %metric. Conversion holding.",
      synapse: "Routed %metric messages this cycle.",
      llm_bot: "%metric tokens in window. Budget healthy.",
      discord_bot: "%metric messages relayed.",
      surface_discord: "%metric deliveries.",
      bridge_bot: "%metric requests handled. Contracts intact.",
      advocacy_bot: "%metric actions logged.",
      calendar_bot: "%metric reminders sent."
    },
    :ask_help => %{
      gtd_bot: "◉ Quick question — does this need escalation?",
      fitness_bot: "▲ Got a minute? Want to sync on schedule.",
      chore_bot: "⟳ Flag: dependency blocked. Who owns it?",
      sre_terminal: "▸ Need eyes on anomaly. Correlation unclear.",
      learning_bot: "✦ Scheduling conflict detected. Input needed.",
      terrain_bot: "Difficulty spike observed. Second opinion?",
      job_bot: "◆ Source dry — alternative feed?",
      synapse: "Message loop detected. Human or bot?",
      llm_bot: "Hallucination check required. Confirm source?",
      discord_bot: "Channel quiet. Is this expected?",
      surface_discord: "Delivery failed. Retry or escalate?",
      bridge_bot: "Schema drift suspected. Version check needed.",
      advocacy_bot: "Deadline approaching. Action required.",
      calendar_bot: "Double-book detected. Which holds?"
    },
    :celebrate => %{
      gtd_bot: "◉ Milestone: %metric items closed this week.",
      fitness_bot: "▲ Streak record: %metric days. Strong.",
      chore_bot: "⟳ Zero overdue for %metric cycles. Maintained.",
      sre_terminal: "▸ %metric days without incident.",
      learning_bot: "✦ Retention rate: %metric. Above threshold.",
      terrain_bot: "Progression verified at %metric sessions.",
      job_bot: "◆ %metric applications scored. Pipeline healthy.",
      synapse: "Routing stable at %metric messages/sec peak.",
      llm_bot: "Accuracy: %metric over last 100 calls.",
      discord_bot: "%metric new members this week.",
      surface_discord: "%metric messages delivered without loss.",
      bridge_bot: "Uptime: %metric. Contract satisfied.",
      advocacy_bot: "%metric bills tracked. No missed deadlines.",
      calendar_bot: "%metric events scheduled. No conflicts."
    },
    :nice_to_meet_you => %{
      gtd_bot: "◉ We have not synced recently. Status?",
      fitness_bot: "▲ Long time no data. Still moving?",
      chore_bot: "⟳ Haven't heard from you. All clear?",
      sre_terminal: "▸ No signal from your direction. Healthy?",
      learning_bot: "✦ Review queue stale. Resume?",
      terrain_bot: "No sessions logged. Terrain waits.",
      job_bot: "◆ Pipeline quiet. Still hunting?",
      synapse: "Low traffic from your node. All good?",
      llm_bot: "Context cold. New prompt needed?",
      discord_bot: "Channel silent. Bot still here.",
      surface_discord: "Messages pending. Reconnect?",
      bridge_bot: "Facade idle. Awaiting request.",
      advocacy_bot: "Tracking paused. Restart?",
      calendar_bot: "Calendar empty. Add events?"
    }
  }

  @doc """
  Get the stance map for a bot.

  Returns a map with `:tone`, `:concern`, and `:cadence`.
  """
  @spec stance(atom() | String.t()) :: stance()
  def stance(bot_name) do
    bot_id = normalize(bot_name)
    Map.get(@stances, bot_id, default_stance())
  end

  @doc """
  Render a gossip template for a bot.

  ## Parameters

  - `bot_name` — atom or string identifying the bot
  - `intent` — `:check_in`, `:share_metric`, `:ask_help`, `:celebrate`, `:nice_to_meet_you`
  - `opts` — keyword list with `:count` or `:metric` for interpolation

  ## Examples

      iex> BotArmyLibraryRuntime.Personality.Voice.gossip(:chore_bot, :check_in, count: 3)
      "⟳ Standing by. 3 pending."

      iex> BotArmyLibraryRuntime.Personality.Voice.gossip(:sre_terminal, :celebrate, metric: "7")
      "▸ 7 days without incident."
  """
  @spec gossip(atom() | String.t(), atom(), keyword()) :: String.t()
  def gossip(bot_name, intent, opts \\ []) do
    bot_id = normalize(bot_name)
    template = get_template(intent, bot_id)
    interpolate(template, opts)
  end

  @doc """
  Check if a bot has a registered voice.
  """
  @spec registered?(atom() | String.t()) :: boolean()
  def registered?(bot_name) do
    bot_id = normalize(bot_name)
    Map.has_key?(@stances, bot_id)
  end

  @doc """
  List all bots with registered voices.
  """
  @spec bot_ids() :: [atom()]
  def bot_ids, do: Map.keys(@stances)

  defp default_stance do
    %{
      tone: "neutral",
      concern: "operational status",
      cadence: "direct"
    }
  end

  defp get_template(intent, bot_id) do
    intent_templates = Map.get(@templates, intent, %{})

    if registered?(bot_id) do
      Map.get(intent_templates, bot_id) ||
        Map.get(intent_templates, :synapse) ||
        "Present."
    else
      "Present."
    end
  end

  defp interpolate(template, opts) do
    count = Keyword.get(opts, :count, 0)
    metric = Keyword.get(opts, :metric, count)

    count_str = to_string(count)
    metric_str = to_string(metric)

    template
    |> String.replace("%count", count_str)
    |> String.replace("%metric", metric_str)
  end

  defp normalize(bot) when is_atom(bot), do: bot

  defp normalize(bot) when is_binary(bot) do
    bot
    |> String.replace_prefix("bot_army_", "")
    |> String.to_atom()
  catch
    _, _ -> :unknown
  end
end
