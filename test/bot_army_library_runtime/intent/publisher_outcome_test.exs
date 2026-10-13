defmodule BotArmyLibraryRuntime.Intent.PublisherOutcomeTest do
  @moduledoc """
  Behavioural guard for the intent publisher's caller contract.

  The sibling `publisher_veto_subscription_test.exs` is a *source* lint: it reads
  `publisher.ex` and asserts on the text of the veto window. That is how a dead
  branch survived review — the file *looked* right:

      case result do
        :vetoed -> result
        :proceed -> {:proceed, intent_id, endorsements}
      end

  `collect_responses/5` never returns those bare atoms; it returns
  `{{:proceed, intent_id, endorsements}, endorsements}`. The clause was unreachable
  while the older `:ok = Gnat.sub` MatchError killed the publisher first. With that
  fixed (0.14.92) every intent pulse died here instead, live on 2026-10-13:

      ** (CaseClauseError) no case clause matching: {:proceed, "94391376-…", []}
      (bot_army_library_runtime 0.14.92) publisher.ex:254: wait_for_vetoes/3

  These tests *execute* the mapping, so a shape change cannot pass silently.
  """
  use ExUnit.Case, async: false

  @moduletag :core

  alias BotArmyLibraryRuntime.Intent.Publisher

  describe "veto_outcome/3 — what the six intent evaluators pattern-match on" do
    test "a closed window proceeds, carrying its endorsements" do
      endorsements = [{"gtd", "corr-1"}]

      assert Publisher.veto_outcome(
               {:proceed, "intent-1", endorsements},
               "intent-1",
               endorsements
             ) ==
               {:proceed, "intent-1", endorsements}
    end

    test "a veto keeps the vetoing bot and its reason" do
      assert Publisher.veto_outcome({:vetoed, "gtd", "not while I'm mid-task"}, "intent-1", []) ==
               {:vetoed, "gtd", "not while I'm mid-task"}
    end

    test "an unrecognised shape fails open rather than killing the evaluator" do
      assert Publisher.veto_outcome({:surprise, 1, 2}, "intent-1", []) ==
               {:proceed, "intent-1", []}
    end
  end

  describe "publish_intent/4 when intents are disabled" do
    setup do
      previous = Application.get_env(:bot_army_library_runtime, :intent)

      on_exit(fn ->
        if previous do
          Application.put_env(:bot_army_library_runtime, :intent, previous)
        else
          Application.delete_env(:bot_army_library_runtime, :intent)
        end
      end)

      :ok
    end

    test "returns {:error, :disabled} instead of publishing anyway" do
      Application.put_env(:bot_army_library_runtime, :intent, enabled: false)

      assert Publisher.publish_intent("fitness", "act") == {:error, :disabled}
    end
  end
end
