defmodule BotArmyRuntime.NATS.Conversation.ManagerTest do
  use ExUnit.Case
  @moduletag :nats

  alias BotArmyRuntime.NATS.Conversation.Manager

  test "cleanup keeps recent terminal conversations without crashing fold accumulator" do
    table = :ets.new(:conversation_manager_cleanup_test, [:set])
    now = System.monotonic_time(:millisecond)

    recent = %{
      status: :timed_out,
      cancelled_at: nil,
      timed_out_at: now,
      conversation_id: "recent"
    }

    stale = %{
      status: :completed,
      cancelled_at: nil,
      timed_out_at: now - 301_000,
      conversation_id: "stale"
    }

    :ets.insert(table, {"recent", recent})
    :ets.insert(table, {"stale", stale})

    try do
      assert {:noreply, %{ets: ^table}} =
               Manager.handle_info(:cleanup, %{ets: table, conn: nil, subscriptions: []})

      assert [{"recent", ^recent}] = :ets.lookup(table, "recent")
      assert [] = :ets.lookup(table, "stale")
    after
      :ets.delete(table)
    end
  end
end
