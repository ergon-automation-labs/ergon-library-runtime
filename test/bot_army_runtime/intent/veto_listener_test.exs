defmodule BotArmyRuntime.Intent.VetoListenerTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyRuntime.Intent.Schema
  alias BotArmyRuntime.Intent.VetoListener

  describe "rule_matches?/4" do
    test "matches when all rule keys match" do
      envelope = %{"bot_id" => "gtd", "action" => "nudge", "intent_id" => "abc123"}
      rule = [bot: "gtd", action: "nudge"]

      assert VetoListener.rule_matches?(rule, envelope, "gtd", "nudge")
    end

    test "does not match when bot differs" do
      envelope = %{"bot_id" => "gtd", "action" => "nudge", "intent_id" => "abc123"}
      rule = [bot: "fitness", action: "nudge"]

      refute VetoListener.rule_matches?(rule, envelope, "gtd", "nudge")
    end

    test "does not match when action differs" do
      envelope = %{"bot_id" => "gtd", "action" => "nudge", "intent_id" => "abc123"}
      rule = [bot: "gtd", action: "remind"]

      refute VetoListener.rule_matches?(rule, envelope, "gtd", "nudge")
    end

    test "matches when only bot is specified (wildcard action)" do
      envelope = %{"bot_id" => "gtd", "action" => "nudge"}
      rule = [bot: "gtd"]

      assert VetoListener.rule_matches?(rule, envelope, "gtd", "nudge")
    end

    test "matches when only action is specified (wildcard bot)" do
      envelope = %{"bot_id" => "gtd", "action" => "nudge"}
      rule = [action: "nudge"]

      assert VetoListener.rule_matches?(rule, envelope, "gtd", "nudge")
    end

    test "matches with custom function that returns true" do
      envelope = %{
        "bot_id" => "gtd",
        "action" => "nudge",
        "context_snapshot" => %{"stale_count" => 10}
      }

      custom_fn = fn env ->
        get_in(env, ["context_snapshot", "stale_count"]) |> Kernel.>(5)
      end

      rule = [bot: "gtd", custom: custom_fn]

      assert VetoListener.rule_matches?(rule, envelope, "gtd", "nudge")
    end

    test "does not match when custom function returns false" do
      envelope = %{
        "bot_id" => "gtd",
        "action" => "nudge",
        "context_snapshot" => %{"stale_count" => 2}
      }

      custom_fn = fn env ->
        get_in(env, ["context_snapshot", "stale_count"]) |> Kernel.>(5)
      end

      rule = [bot: "gtd", custom: custom_fn]

      refute VetoListener.rule_matches?(rule, envelope, "gtd", "nudge")
    end

    test "empty rule matches everything" do
      envelope = %{"bot_id" => "any", "action" => "anything"}

      assert VetoListener.rule_matches?([], envelope, "any", "anything")
    end
  end

  describe "build_veto_reason/2" do
    test "builds default reason from bot and action" do
      rule = [bot: "gtd", action: "nudge"]
      envelope = %{}

      assert VetoListener.build_veto_reason(rule, envelope) == "gtd.nudge vetoed by policy"
    end

    test "uses custom reason string" do
      rule = [bot: "gtd", action: "nudge", reason: "user is in focus mode"]
      envelope = %{}

      assert VetoListener.build_veto_reason(rule, envelope) == "user is in focus mode"
    end

    test "uses custom reason function" do
      reason_fn = fn env ->
        count = get_in(env, ["context_snapshot", "stale_count"]) || 0
        "#{count} stale tasks is below threshold"
      end

      rule = [bot: "gtd", action: "nudge", reason: reason_fn]
      envelope = %{"context_snapshot" => %{"stale_count" => 2}}

      assert VetoListener.build_veto_reason(rule, envelope) == "2 stale tasks is below threshold"
    end
  end

  describe "schema integration" do
    test "veto listener uses correct wildcard subject" do
      wildcard = Schema.all_intents()
      assert wildcard == "bot_army.*.intent.>"
    end

    test "veto subject is parseable from intent subject" do
      subject = Schema.intent_subject("gtd", "nudge")
      veto_subj = Schema.veto_subject("gtd", "nudge")

      assert veto_subj == "bot_army.gtd.intent.nudge.response"

      {:ok, {bot, action}} = Schema.parse_subject(subject)
      assert bot == "gtd"
      assert action == "nudge"
    end
  end

  describe "veto audit log" do
    test "veto event subject follows convention" do
      event_subject = "events.bot_army.intent.vetoed"
      assert String.starts_with?(event_subject, "events.bot_army.")
    end

    test "log entry contains required fields" do
      entry = %{
        vetoed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        vetoing_bot: "fitness",
        target_bot: "gtd",
        action: "nudge",
        reason: "no recent workout activity",
        rule: "gtd.nudge +custom",
        correlation_id: "abc-123",
        intent_id: "def-456"
      }

      assert Map.has_key?(entry, :vetoed_at)
      assert Map.has_key?(entry, :vetoing_bot)
      assert Map.has_key?(entry, :target_bot)
      assert Map.has_key?(entry, :action)
      assert Map.has_key?(entry, :reason)
      assert Map.has_key?(entry, :rule)
      assert Map.has_key?(entry, :correlation_id)
      assert Map.has_key?(entry, :intent_id)
    end
  end
end
