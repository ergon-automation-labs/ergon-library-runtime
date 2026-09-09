defmodule BotArmyLibraryRuntime.HealthPulsePublisherTest do
  use ExUnit.Case, async: false

  alias BotArmyLibraryRuntime.HealthPulsePublisher

  # Short interval; publishes degrade gracefully to {:error, _} without a
  # NATS connection in :test — the contract is "never crash, keep pulsing".
  @interval 20

  test "pulses on interval and survives failed publishes" do
    pid = start_supervised!({HealthPulsePublisher, [app_name: :bot_army_test_bot, service: "test_bot", interval_ms: @interval]})

    # Two pulses (~40ms) + settle; the GenServer must still be alive and
    # scheduled for more pulses.
    :timer.sleep(120)
    assert Process.alive?(pid)

    state = :sys.get_state(pid)
    assert state.service == "test_bot"
    assert state.app_name == :bot_army_test_bot
  end

  test "default service name derived from app_name" do
    pid = start_supervised!({HealthPulsePublisher, [app_name: :bot_army_graphify_cache, interval_ms: 60_000]})

    :timer.sleep(10)
    state = :sys.get_state(pid)
    assert state.service == "graphify_cache"
  end
end