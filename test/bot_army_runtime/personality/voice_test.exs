defmodule BotArmyRuntime.Personality.VoiceTest do
  use ExUnit.Case
  @moduletag :format
  alias BotArmyRuntime.Personality.Voice

  describe "stance/1" do
    test "returns GTD stance" do
      stance = Voice.stance(:gtd_bot)
      assert stance.tone == "next-action"
      assert stance.concern == "clarity and momentum"
      assert stance.cadence == "concise, list-oriented"
    end

    test "returns SRE stance" do
      stance = Voice.stance(:sre_terminal)
      assert stance.tone == "alert"
      assert stance.concern == "signal vs noise"
      assert stance.cadence == "terse, metric-heavy"
    end

    test "returns default for unknown bot" do
      stance = Voice.stance(:unknown_bot)
      assert stance.tone == "neutral"
      assert stance.concern == "operational status"
      assert stance.cadence == "direct"
    end

    test "handles string bot name" do
      stance = Voice.stance("chore_bot")
      assert stance.tone == "dutiful"
    end
  end

  describe "gossip/3" do
    test "gtd check_in" do
      msg = Voice.gossip(:gtd_bot, :check_in, count: 14)
      assert msg == "◉ Present. 14 items active."
    end

    test "fitness celebrate" do
      msg = Voice.gossip(:fitness_bot, :celebrate, metric: 7)
      assert msg == "▲ Streak record: 7 days. Strong."
    end

    test "sre ask_help" do
      msg = Voice.gossip(:sre_terminal, :ask_help)
      assert msg == "▸ Need eyes on anomaly. Correlation unclear."
    end

    test "chore share_metric" do
      msg = Voice.gossip(:chore_bot, :share_metric, metric: 5)
      assert msg == "⟳ Completed 5. Nothing overdue."
    end

    test "bridge nice_to_meet_you" do
      msg = Voice.gossip(:bridge_bot, :nice_to_meet_you)
      assert msg == "Facade idle. Awaiting request."
    end

    test "uses count when metric is nil" do
      msg = Voice.gossip(:gtd_bot, :share_metric, count: 3)
      assert msg == "◉ Processed 3 today. Inbox is clear."
    end

    test "handles unknown bot with default template" do
      msg = Voice.gossip(:unknown, :check_in, count: 0)
      assert msg == "Present."
    end
  end

  describe "registered?/1" do
    test "returns true for known bots" do
      assert Voice.registered?(:gtd_bot)
      assert Voice.registered?(:fitness_bot)
      assert Voice.registered?(:chore_bot)
    end

    test "returns false for unknown bots" do
      refute Voice.registered?(:unknown)
      refute Voice.registered?(:nonexistent)
    end
  end

  describe "bot_ids/0" do
    test "returns list of registered bot ids" do
      ids = Voice.bot_ids()
      assert :gtd_bot in ids
      assert :fitness_bot in ids
      assert :chore_bot in ids
      assert :sre_terminal in ids
    end
  end
end
