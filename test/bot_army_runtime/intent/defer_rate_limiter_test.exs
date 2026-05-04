defmodule BotArmyRuntime.Intent.DeferRateLimiterTest do
  use ExUnit.Case, async: false

  @moduletag :core

  alias BotArmyRuntime.Intent.DeferRateLimiter

  setup do
    # Ensure the ETS table exists and clear it for each test
    try do
      :ets.new(:defer_rate_limit, [:named_table, :set, :public, read_concurrency: true])
    rescue
      ArgumentError ->
        :ets.delete_all_objects(:defer_rate_limit)
    end

    on_exit(fn ->
      try do
        :ets.delete_all_objects(:defer_rate_limit)
      rescue
        ArgumentError -> :ok
      end
    end)

    :ok
  end

  describe "check/1" do
    test "returns :allowed for a new key" do
      assert :allowed = DeferRateLimiter.check("test_bot:new_action_#{:erlang.unique_integer()}")
    end

    test "returns :rate_limited when interval has not elapsed" do
      key = "test_bot:rate_limited_action_#{:erlang.unique_integer()}"
      DeferRateLimiter.mark(key)
      result = DeferRateLimiter.check(key)
      assert {:rate_limited, remaining} = result
      assert remaining > 0
    end
  end

  describe "check_and_mark/1" do
    test "returns :allowed and marks on first call" do
      key = "test_bot:check_and_mark_#{:erlang.unique_integer()}"
      assert :allowed = DeferRateLimiter.check_and_mark(key)
    end

    test "returns :rate_limited on immediate second call" do
      key = "test_bot:double_mark_#{:erlang.unique_integer()}"
      assert :allowed = DeferRateLimiter.check_and_mark(key)
      result = DeferRateLimiter.check_and_mark(key)
      assert {:rate_limited, _remaining} = result
    end
  end

  describe "mark/1" do
    test "marks a key as seen" do
      key = "test_bot:mark_test_#{:erlang.unique_integer()}"
      assert :ok = DeferRateLimiter.mark(key)
      assert {:rate_limited, _} = DeferRateLimiter.check(key)
    end
  end
end