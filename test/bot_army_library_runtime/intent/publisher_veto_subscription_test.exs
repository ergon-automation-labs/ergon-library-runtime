defmodule BotArmyLibraryRuntime.Intent.PublisherVetoSubscriptionTest do
  @moduledoc """
  Regression guard for the live intent-evaluator crash loop measured 2026-10-13.

  `wait_for_vetoes/3` opened the veto window with `:ok = Gnat.sub(conn, self(),
  veto_subj)`. `Gnat.sub/3` returns `{:ok, sid}`, so the hard `:ok =` match raised
  `MatchError {:ok, 303}` on **every** intent — the 303 was a subscription id, not
  a count. The unsubscribe on the next line passed the *subject* where `Gnat.unsub/3`
  wants the *sid*, so the veto subscription leaked as well.

  The window now uses the non-fatal `Connection.safe_sub/3` (shape `{:ok, sid} |
  {:error, reason}`) and closes with `Connection.unsub(conn, sid)`. This test reads
  the source so the old shape cannot creep back in — it looks entirely reasonable
  in review.
  """
  use ExUnit.Case, async: true

  @moduletag :core

  @source Path.expand("../../../lib/bot_army_library_runtime/intent/publisher.ex", __DIR__)

  test "the veto window never hard-matches Gnat.sub/3" do
    refute File.read!(@source) =~ ":ok = Gnat.sub",
           "Gnat.sub/3 returns {:ok, sid}; `:ok = Gnat.sub(...)` crashes the publisher"
  end

  test "the veto window unsubscribes by sid, not by subject" do
    refute File.read!(@source) =~ "Gnat.unsub(conn, veto_subj)",
           "Gnat.unsub/3 takes the sid; passing the subject leaks the veto subscription"
  end

  test "the veto window uses the runtime's non-fatal wrappers" do
    source = File.read!(@source)

    assert source =~ "Connection.safe_sub(conn, self(), veto_subj)"
    assert source =~ "Connection.unsub(conn, sid)"
  end
end
