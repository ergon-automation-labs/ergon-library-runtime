defmodule BotArmyLibraryRuntime.Personality.ThemeConfig do
  @moduledoc """
  Theme configuration for the Resistance Chronicle.

  A theme defines vocabulary, tone, and framing templates that the
  ThemeRenderer uses to convert plain-English data into campaign-flavored copy.

  Built-in packs: cyberpunk/0, fantasy/0, plain/0.
  """

  @type template_map :: %{
          prefix: String.t() | nil,
          suffix: String.t() | nil,
          label: String.t() | nil
        }

  @type npc_persona :: %{
          name: String.t(),
          style: String.t()
        }

  @type t :: %__MODULE__{
          setting: String.t(),
          tone: String.t(),
          mechanic: String.t(),
          vocabulary: %{String.t() => String.t()},
          templates: %{String.t() => template_map()},
          npc_personas: %{String.t() => npc_persona()},
          changed_at: String.t() | nil,
          changed_by: String.t() | nil
        }

  @enforce_keys [:setting, :tone, :mechanic, :vocabulary]
  defstruct [
    :setting,
    :tone,
    :mechanic,
    :vocabulary,
    :templates,
    :npc_personas,
    :changed_at,
    :changed_by
  ]

  def cyberpunk do
    %__MODULE__{
      setting: "cyberpunk",
      tone: "hopeful",
      mechanic: "bounties",
      vocabulary: %{
        "bug" => "goblin raid",
        "task" => "bounty",
        "deploy" => "supply drop",
        "crash" => "wall breach",
        "poll" => "town vote",
        "project" => "campaign",
        "issue" => "distress signal",
        "review" => "debrief",
        "alert" => "sector alarm",
        "queue" => "waiting list",
        "streak" => "hot run",
        "complete" => "cleared",
        "fail" => "compromised",
        "error" => "corruption",
        "user" => "operative",
        "team" => "cell",
        "sprint" => "push"
      },
      templates: %{
        "task" => %{prefix: "Bounty:", suffix: nil, label: "bounty"},
        "bug" => %{prefix: "Raid alert:", suffix: nil, label: "goblin raid"},
        "poll" => %{prefix: "Town Vote:", suffix: nil, label: "town vote"},
        "deploy" => %{prefix: "Supply Drop:", suffix: "dispatched", label: "supply drop"},
        "review" => %{prefix: "Debrief:", suffix: nil, label: "debrief"}
      },
      npc_personas: %{
        "gtd_bot" => %{name: "The Archivist", style: "laconic, precise"},
        "synapse" => %{name: "The Keeper", style: "watchful, warm, never sleeps"},
        "llm_bot" => %{name: "The Bard", style: "lyrical, embellished"},
        "sre_terminal" => %{name: "The Warden", style: "gruff, practical"},
        "fitness_bot" => %{name: "The Drill Sergeant", style: "loud, encouraging"},
        "terrain_bot" => %{name: "The Shapeshifter", style: "eerie, adaptive"},
        "chore_bot" => %{name: "The Steward", style: "dutiful, orderly"},
        "job_bot" => %{name: "The Fixer", style: "wired, urgent"},
        "bridge_bot" => %{name: "The Scribe", style: "neutral, exact"},
        "discord_bot" => %{name: "The Herald", style: "formal, loud"},
        "surface_discord" => %{name: "The Messenger", style: "quick, plain"},
        "backups_bot" => %{name: "The Archivist", style: "careful, patient"}
      }
    }
  end

  def fantasy do
    %__MODULE__{
      setting: "fantasy",
      tone: "whimsical",
      mechanic: "exploration",
      vocabulary: %{
        "bug" => "curse",
        "task" => "quest",
        "deploy" => "enchantment",
        "crash" => "dark ritual",
        "poll" => "council vote",
        "project" => "chronicle",
        "issue" => "prophecy",
        "review" => "council of elders",
        "alert" => "warden's horn",
        "queue" => "waiting line",
        "streak" => "blessed run",
        "complete" => "fulfilled",
        "fail" => "befallen",
        "error" => "dark magic",
        "user" => "adventurer",
        "team" => "party",
        "sprint" => "march"
      },
      templates: %{
        "task" => %{prefix: "Quest:", suffix: nil, label: "quest"},
        "bug" => %{prefix: "A curse afflicts:", suffix: nil, label: "curse"},
        "poll" => %{prefix: "Council Vote:", suffix: nil, label: "council vote"},
        "deploy" => %{prefix: "Enchantment:", suffix: "cast", label: "enchantment"},
        "review" => %{prefix: "Council of Elders:", suffix: nil, label: "council"}
      },
      npc_personas: %{
        "gtd_bot" => %{name: "The Lorekeeper", style: "ancient, whispering"},
        "synapse" => %{name: "The Innkeeper", style: "quietly knowing, always present"},
        "llm_bot" => %{name: "The Bard", style: "lyrical, embellished"},
        "sre_terminal" => %{name: "The Sentinel", style: "solemn, watchful"},
        "fitness_bot" => %{name: "The Drillmaster", style: "booming, hearty"},
        "terrain_bot" => %{name: "The Shapeshifter", style: "eerie, adaptive"},
        "chore_bot" => %{name: "The Steward", style: "dutiful, orderly"},
        "job_bot" => %{name: "The Fixer", style: "wired, urgent"},
        "bridge_bot" => %{name: "The Scribe", style: "neutral, exact"},
        "discord_bot" => %{name: "The Herald", style: "formal, loud"},
        "surface_discord" => %{name: "The Messenger", style: "quick, plain"},
        "backups_bot" => %{name: "The Archivist", style: "careful, patient"}
      }
    }
  end

  def plain do
    %__MODULE__{
      setting: "plain",
      tone: "neutral",
      mechanic: "standard",
      vocabulary: %{},
      templates: %{},
      npc_personas: %{}
    }
  end

  def from_map(map) when is_map(map) do
    %__MODULE__{
      setting: Map.fetch!(map, "setting"),
      tone: Map.fetch!(map, "tone"),
      mechanic: Map.fetch!(map, "mechanic"),
      vocabulary: Map.get(map, "vocabulary", %{}),
      templates: normalize_templates(Map.get(map, "templates", %{})),
      npc_personas: Map.get(map, "npc_personas", %{}),
      changed_at: Map.get(map, "changed_at"),
      changed_by: Map.get(map, "changed_by")
    }
  end

  def to_map(%__MODULE__{} = theme) do
    %{
      "setting" => theme.setting,
      "tone" => theme.tone,
      "mechanic" => theme.mechanic,
      "vocabulary" => theme.vocabulary,
      "templates" => theme.templates,
      "npc_personas" => theme.npc_personas,
      "changed_at" => theme.changed_at,
      "changed_by" => theme.changed_by
    }
  end

  defp normalize_templates(templates) when is_map(templates) do
    Map.new(templates, fn {key, val} ->
      normalized =
        case val do
          %{prefix: _, suffix: _, label: _} = t ->
            t

          %{"prefix" => p, "suffix" => s, "label" => l} ->
            %{prefix: p, suffix: s, label: l}

          _ ->
            %{prefix: nil, suffix: nil, label: nil}
        end

      {key, normalized}
    end)
  end
end
