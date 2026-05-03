defmodule BotArmyRuntime.Intent.SchemaTest do
  use ExUnit.Case
  @moduletag :nats

  alias BotArmyRuntime.Intent.Schema

  describe "intent_subject/2" do
    test "builds intent subject from bot name and action" do
      assert Schema.intent_subject("gtd", "nudge") == "bot_army.gtd.intent.nudge"
    end

    test "builds intent subject for fitness bot" do
      assert Schema.intent_subject("fitness", "suggest") == "bot_army.fitness.intent.suggest"
    end
  end

  describe "veto_subject/2" do
    test "builds veto response subject" do
      assert Schema.veto_subject("gtd", "nudge") == "bot_army.gtd.intent.nudge.response"
    end
  end

  describe "all_intents_for/1" do
    test "builds wildcard for a specific bot" do
      assert Schema.all_intents_for("gtd") == "bot_army.gtd.intent.>"
    end
  end

  describe "all_intents/0" do
    test "builds wildcard for all bots" do
      assert Schema.all_intents() == "bot_army.*.intent.>"
    end
  end

  describe "parse_subject/1" do
    test "parses valid intent subject" do
      assert Schema.parse_subject("bot_army.gtd.intent.nudge") == {:ok, {"gtd", "nudge"}}
    end

    test "parses veto response subject" do
      assert Schema.parse_subject("bot_army.gtd.intent.nudge.response") == {:ok, {"gtd", "nudge"}}
    end

    test "returns error for invalid subject" do
      assert Schema.parse_subject("gtd.task.create") == {:error, :invalid_format}
    end

    test "returns error for partial subject" do
      assert Schema.parse_subject("bot_army.gtd") == {:error, :invalid_format}
    end
  end

  describe "intent?/1" do
    test "returns true for intent subjects" do
      assert Schema.intent?("bot_army.gtd.intent.nudge") == true
    end

    test "returns true for veto response subjects" do
      assert Schema.intent?("bot_army.gtd.intent.nudge.response") == true
    end

    test "returns false for request/reply subjects" do
      assert Schema.intent?("gtd.task.create") == false
    end

    test "returns false for health subjects" do
      assert Schema.intent?("bot.army.pulse.gtd_bot") == false
    end
  end

  describe "veto_response?/1" do
    test "returns true for veto response subjects" do
      assert Schema.veto_response?("bot_army.gtd.intent.nudge.response") == true
    end

    test "returns false for intent subjects" do
      assert Schema.veto_response?("bot_army.gtd.intent.nudge") == false
    end

    test "returns false for other subjects" do
      assert Schema.veto_response?("gtd.task.list") == false
    end
  end

  describe "veto_timeout_ms/0" do
    test "returns default timeout" do
      assert Schema.veto_timeout_ms() == 2_000
    end
  end
end
