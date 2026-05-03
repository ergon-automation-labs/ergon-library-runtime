defmodule BotArmyRuntime.Personality.ThemeConfigTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyRuntime.Personality.ThemeConfig

  describe "cyberpunk/0" do
    test "returns a ThemeConfig with setting cyberpunk" do
      theme = ThemeConfig.cyberpunk()
      assert theme.setting == "cyberpunk"
    end

    test "has non-empty vocabulary" do
      theme = ThemeConfig.cyberpunk()
      assert map_size(theme.vocabulary) > 0
    end

    test "has template for task type" do
      theme = ThemeConfig.cyberpunk()
      assert Map.has_key?(theme.templates, "task")
    end

    test "vocabulary maps task to bounty" do
      theme = ThemeConfig.cyberpunk()
      assert theme.vocabulary["task"] == "bounty"
    end

    test "has npc personas" do
      theme = ThemeConfig.cyberpunk()
      assert map_size(theme.npc_personas) > 0
    end
  end

  describe "fantasy/0" do
    test "returns a ThemeConfig with setting fantasy" do
      theme = ThemeConfig.fantasy()
      assert theme.setting == "fantasy"
    end

    test "vocabulary maps task to quest" do
      theme = ThemeConfig.fantasy()
      assert theme.vocabulary["task"] == "quest"
    end
  end

  describe "plain/0" do
    test "returns a ThemeConfig with empty vocabulary" do
      theme = ThemeConfig.plain()
      assert theme.vocabulary == %{}
    end

    test "templates are empty" do
      theme = ThemeConfig.plain()
      assert theme.templates == %{}
    end
  end

  describe "from_map/1" do
    test "builds struct from JSON-style map" do
      map = %{
        "setting" => "cyberpunk",
        "tone" => "hopeful",
        "mechanic" => "bounties",
        "vocabulary" => %{"task" => "bounty"},
        "templates" => %{"task" => %{"prefix" => "Bounty:", "suffix" => nil, "label" => "bounty"}},
        "npc_personas" => %{},
        "changed_at" => "2026-05-03T00:00:00Z",
        "changed_by" => "player"
      }

      theme = ThemeConfig.from_map(map)
      assert theme.setting == "cyberpunk"
      assert theme.vocabulary["task"] == "bounty"
      assert theme.changed_by == "player"
    end

    test "raises on missing required setting key" do
      assert_raise KeyError, fn ->
        ThemeConfig.from_map(%{"tone" => "hopeful", "mechanic" => "bounties"})
      end
    end

    test "fills defaults for optional fields" do
      map = %{"setting" => "plain", "tone" => "neutral", "mechanic" => "standard"}
      theme = ThemeConfig.from_map(map)
      assert theme.vocabulary == %{}
      assert theme.templates == %{}
      assert theme.npc_personas == %{}
      assert theme.changed_at == nil
    end

    test "normalizes atom-keyed templates to atom-keyed" do
      map = %{
        "setting" => "test",
        "tone" => "neutral",
        "mechanic" => "standard",
        "templates" => %{
          "task" => %{prefix: "Quest:", suffix: nil, label: "quest"}
        }
      }

      theme = ThemeConfig.from_map(map)
      assert theme.templates["task"].prefix == "Quest:"
    end
  end

  describe "to_map/1" do
    test "round-trips through from_map preserving all fields" do
      original = %{
        "setting" => "cyberpunk",
        "tone" => "hopeful",
        "mechanic" => "bounties",
        "vocabulary" => %{"task" => "bounty"},
        "templates" => %{},
        "npc_personas" => %{},
        "changed_at" => "2026-05-03T00:00:00Z",
        "changed_by" => "player"
      }

      result =
        original
        |> ThemeConfig.from_map()
        |> ThemeConfig.to_map()

      assert result["setting"] == "cyberpunk"
      assert result["vocabulary"]["task"] == "bounty"
      assert result["changed_by"] == "player"
    end
  end
end
