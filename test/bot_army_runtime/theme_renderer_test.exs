defmodule BotArmyRuntime.ThemeRendererTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyRuntime.ThemeRenderer
  alias BotArmyRuntime.Personality.ThemeConfig

  describe "render/2" do
    test "with cyberpunk theme, renders a task type with prefix" do
      data = %{"type" => "task", "title" => "Fix email pipeline", "id" => "abc123"}
      result = ThemeRenderer.render(data, ThemeConfig.cyberpunk())

      assert result["flavored"] == "Bounty: Fix email pipeline"
      assert result["prefix"] == "Bounty:"
      assert result["label"] == "bounty"
      assert result["original"] == "Fix email pipeline"
      assert result["id"] == "abc123"
    end

    test "with plain theme, returns data with no flavoring" do
      data = %{"type" => "task", "title" => "Fix email pipeline"}
      result = ThemeRenderer.render(data, ThemeConfig.plain())

      assert result["flavored"] == "Fix email pipeline"
      assert result["label"] == "task"
      assert result["prefix"] == nil
    end

    test "preserves pass-through fields" do
      data = %{
        "type" => "task",
        "title" => "Fix email",
        "id" => "abc123",
        "count" => 5,
        "url" => "https://example.com"
      }

      result = ThemeRenderer.render(data, ThemeConfig.cyberpunk())

      assert result["id"] == "abc123"
      assert result["count"] == 5
      assert result["url"] == "https://example.com"
    end

    test "applies vocabulary substitution to title" do
      data = %{"type" => "task", "title" => "Complete the task"}
      result = ThemeRenderer.render(data, ThemeConfig.cyberpunk())

      assert result["title"] == "Complete the bounty"
    end

    test "applies vocabulary substitution to description" do
      data = %{"type" => "task", "title" => "Fix", "description" => "A new task to fix"}
      result = ThemeRenderer.render(data, ThemeConfig.cyberpunk())

      assert result["description"] == "A new bounty to fix"
    end

    test "does NOT substitute vocabulary in id fields" do
      data = %{"type" => "task", "title" => "Fix", "id" => "task-123-deploy"}
      result = ThemeRenderer.render(data, ThemeConfig.cyberpunk())

      assert result["id"] == "task-123-deploy"
    end

    test "determinism: same input + same theme = same output" do
      data = %{"type" => "task", "title" => "Fix email pipeline"}
      result1 = ThemeRenderer.render(data, ThemeConfig.cyberpunk())
      result2 = ThemeRenderer.render(data, ThemeConfig.cyberpunk())

      assert result1["flavored"] == result2["flavored"]
    end

    test "handles missing type gracefully" do
      data = %{"title" => "Fix email"}
      result = ThemeRenderer.render(data, ThemeConfig.cyberpunk())

      assert result["label"] == "unknown"
    end

    test "handles missing title gracefully" do
      data = %{"type" => "task"}
      result = ThemeRenderer.render(data, ThemeConfig.cyberpunk())

      assert result["original"] == ""
    end

    test "with fantasy theme, renders task as quest" do
      data = %{"type" => "task", "title" => "Fix email pipeline"}
      result = ThemeRenderer.render(data, ThemeConfig.fantasy())

      assert result["flavored"] == "Quest: Fix email pipeline"
      assert result["label"] == "quest"
    end

    test "does not mutate the input map" do
      data = %{"type" => "task", "title" => "Fix the task"}
      original_data = Map.put(data, :__original__, true)
      _result = ThemeRenderer.render(data, ThemeConfig.cyberpunk())

      assert data["title"] == "Fix the task"
    end
  end

  describe "substitute/2" do
    test "replaces whole-word matches" do
      assert ThemeRenderer.substitute("A new task", ThemeConfig.cyberpunk()) ==
               "A new bounty"
    end

    test "does not replace substrings" do
      assert ThemeRenderer.substitute("tasking the system", ThemeConfig.cyberpunk()) ==
               "tasking the system"
    end

    test "replaces longest match first" do
      theme =
        ThemeConfig.from_map(%{
          "setting" => "test",
          "tone" => "neutral",
          "mechanic" => "standard",
          "vocabulary" => %{"deploy" => "drop", "deployment" => "deployment-drop"}
        })

      assert ThemeRenderer.substitute("deployment started", theme) ==
               "deployment-drop started"
    end

    test "with empty vocabulary, returns text unchanged" do
      assert ThemeRenderer.substitute("A new task", ThemeConfig.plain()) ==
               "A new task"
    end

    test "replaces multiple terms in one string" do
      result = ThemeRenderer.substitute("A task with a bug", ThemeConfig.cyberpunk())
      assert result == "A bounty with a goblin raid"
    end

    test "vocabulary matching is case-sensitive" do
      assert ThemeRenderer.substitute("Task is done", ThemeConfig.cyberpunk()) ==
               "Task is done"
    end

    test "matches lowercase task in sentence" do
      assert ThemeRenderer.substitute("The task is done", ThemeConfig.cyberpunk()) ==
               "The bounty is done"
    end
  end

  describe "label_for/2" do
    test "returns themed label when vocabulary has mapping" do
      assert ThemeRenderer.label_for("task", ThemeConfig.cyberpunk()) == "bounty"
    end

    test "returns original type when no mapping" do
      assert ThemeRenderer.label_for("unknown_type", ThemeConfig.cyberpunk()) == "unknown_type"
    end

    test "with plain theme, always returns original" do
      assert ThemeRenderer.label_for("task", ThemeConfig.plain()) == "task"
    end

    test "returns template label when vocabulary has no mapping but template does" do
      theme =
        ThemeConfig.from_map(%{
          "setting" => "test",
          "tone" => "neutral",
          "mechanic" => "standard",
          "vocabulary" => %{},
          "templates" => %{"custom" => %{prefix: "Custom:", suffix: nil, label: "custom-label"}}
        })

      assert ThemeRenderer.label_for("custom", theme) == "custom-label"
    end
  end
end
