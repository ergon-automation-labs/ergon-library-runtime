defmodule BotArmyRuntime.Intent.DeferHandlerTest do
  use ExUnit.Case, async: false

  @moduletag :core

  alias BotArmyRuntime.Intent.DeferHandler

  describe "default_prompt_builder/3" do
    test "builds a prompt with action, score, and reason" do
      details = %{score: 0.72, reason: :low_roll, threshold_breakdown: %{}}
      context = %{entry_count: 5, summary: %{}}

      result = DeferHandler.default_prompt_builder("nudge", details, context)

      assert result["intent"] == "classify"
      assert is_binary(result["text"])
      assert result["text"] =~ "nudge"
      assert result["text"] =~ "0.72"
    end

    test "includes context summary when available" do
      details = %{score: 0.5, reason: :below_threshold, threshold_breakdown: %{}}
      context = %{entry_count: 3, summary: %{stale_task_count: 5}}

      result = DeferHandler.default_prompt_builder("remind", details, context)

      assert result["text"] =~ "3 observations"
    end
  end

  describe "handle_defer/5" do
    test "returns :no_handler when disabled" do
      original = Application.get_env(:bot_army_runtime, :defer_handler, [])
      Application.put_env(:bot_army_runtime, :defer_handler, Keyword.put(original, :enabled, false))

      details = %{score: 0.5, reason: :low_roll, threshold_breakdown: %{}}
      config = [prompt_builder: &DeferHandler.default_prompt_builder/3, delivery_fn: fn _, _, _, _ -> :ok end]

      result = DeferHandler.handle_defer("test_bot", "test_action", details, %{}, config)

      assert result == :no_handler

      Application.put_env(:bot_army_runtime, :defer_handler, original)
    end

    test "returns :rate_limited when rate limiter blocks" do
      key = "test_bot:test_action_rate"

      # Ensure rate limiter table exists
      try do
        :ets.new(:defer_rate_limit, [:named_table, :set, :public, read_concurrency: true])
      rescue
        ArgumentError -> :ok
      end

      # Pre-mark to simulate a recent defer
      BotArmyRuntime.Intent.DeferRateLimiter.mark(key)

      details = %{score: 0.5, reason: :low_roll, threshold_breakdown: %{}}
      config = [prompt_builder: &DeferHandler.default_prompt_builder/3, delivery_fn: fn _, _, _, _ -> :ok end]

      result = DeferHandler.handle_defer("test_bot", "test_action_rate", details, %{}, config)

      assert result == :rate_limited
    end
  end

  describe "process_reply/5" do
    test "calls delivery_fn with extracted response" do
      delivered = :agent

      delivery_fn = fn _bot_name, _action, llm_response, _details ->
        send(self(), {:delivered, llm_response})
        :ok
      end

      config = [delivery_fn: delivery_fn]
      body = %{"response" => "Your tasks are waiting for you"}
      details = %{score: 0.5, reason: :low_roll, action: "nudge", threshold_breakdown: %{}}

      result = DeferHandler.process_reply("gtd", "conv-123", body, details, config)

      assert result == :ok
      assert_received {:delivered, %{"response" => "Your tasks are waiting for you"}}
    end

    test "returns error when delivery_fn fails" do
      delivery_fn = fn _, _, _, _ -> {:error, :nats_down} end

      config = [delivery_fn: delivery_fn]
      body = %{"response" => "skip"}
      details = %{score: 0.5, reason: :low_roll, action: "nudge", threshold_breakdown: %{}}

      result = DeferHandler.process_reply("gtd", "conv-123", body, details, config)

      assert result == {:error, :nats_down}
    end

    test "extracts response from nested data map" do
      delivery_fn = fn _, _, llm_response, _ ->
        send(self(), {:nested, llm_response})
        :ok
      end

      config = [delivery_fn: delivery_fn]
      body = %{"data" => %{"response" => "nested reply"}}
      details = %{score: 0.5, reason: :low_roll, action: "nudge", threshold_breakdown: %{}}

      DeferHandler.process_reply("gtd", "conv-456", body, details, config)

      assert_received {:nested, %{"response" => "nested reply"}}
    end
  end
end