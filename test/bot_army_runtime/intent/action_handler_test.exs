defmodule BotArmyRuntime.Intent.ActionHandlerTest do
  use ExUnit.Case, async: false

  alias BotArmyRuntime.Intent.ActionHandler

  describe "execute_action/6" do
    test "returns :no_handler when config is nil" do
      assert ActionHandler.execute_action(
               "gtd",
               "nudge",
               "intent-123",
               %{score: 0.8, reason: :threshold_met},
               [],
               nil
             ) == :no_handler
    end

    test "calls handler_fn and returns {:ok, result}" do
      handler_fn = fn bot_name, action, intent_id, _details, _endorsements ->
        send(self(), {:handler_called, bot_name, action, intent_id})
        :ok
      end

      config = [handler_fn: handler_fn]

      result =
        ActionHandler.execute_action(
          "gtd",
          "nudge",
          "intent-456",
          %{score: 0.8, reason: :threshold_met},
          [{"fitness", "corr-1"}],
          config
        )

      assert {:ok, :ok} = result
      assert_received {:handler_called, "gtd", "nudge", "intent-456"}
    end

    test "returns {:error, reason} when handler_fn raises" do
      handler_fn = fn _bot_name, _action, _intent_id, _details, _endorsements ->
        raise "handler exploded"
      end

      config = [handler_fn: handler_fn]

      result =
        ActionHandler.execute_action(
          "gtd",
          "nudge",
          "intent-789",
          %{score: 0.8, reason: :threshold_met},
          [],
          config
        )

      assert {:error, %RuntimeError{message: "handler exploded"}} = result
    end

    test "handler receives endorsements" do
      endorsements = [{"fitness", "corr-1"}, {"synapse", "corr-2"}]

      handler_fn = fn _bot_name, _action, _intent_id, _details, endorsements ->
        send(self(), {:endorsements, endorsements})
        :ok
      end

      config = [handler_fn: handler_fn]

      ActionHandler.execute_action(
        "gtd",
        "nudge",
        "intent-abc",
        %{score: 0.8, reason: :threshold_met},
        endorsements,
        config
      )

      assert_received {:endorsements, ^endorsements}
    end

    test "handler receives details map" do
      details = %{score: 0.85, reason: :stale_tasks}

      handler_fn = fn _bot_name, _action, _intent_id, details, _endorsements ->
        send(self(), {:details, details})
        :ok
      end

      config = [handler_fn: handler_fn]

      ActionHandler.execute_action(
        "gtd",
        "nudge",
        "intent-def",
        details,
        [],
        config
      )

      assert_received {:details, ^details}
    end

    test "returns error on missing handler_fn key" do
      config = [urgency: "high"]

      result =
        ActionHandler.execute_action(
          "gtd",
          "nudge",
          "intent-ghi",
          %{score: 0.8},
          [],
          config
        )

      assert {:error, %KeyError{}} = result
    end
  end
end