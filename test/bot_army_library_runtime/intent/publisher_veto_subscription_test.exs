defmodule BotArmyLibraryRuntime.Intent.PublisherVetoSubscriptionTest do
  @moduledoc """
  Regression guard for the live intent-evaluator crash loop measured 2026-10-13.

  `wait_for_vetoes/3` opened the veto window with a hard `:ok =` match on
  `Gnat.sub/3`. That call returns `{:ok, sid}`, so the match raised
  `MatchError {:ok, 303}` on **every** intent — the 303 was a subscription id, not
  a count. The unsubscribe on the next line passed the *subject* where `Gnat.unsub/3`
  wants the *sid*, so the veto subscription leaked as well.

  The window now uses the non-fatal `Connection.safe_sub/3` (shape `{:ok, sid} |
  {:error, reason}`) and closes with `Connection.unsub(conn, sid)`. This test reads
  the source so the old shape cannot creep back in — it looks entirely reasonable
  in review. Comments are stripped before matching, so documentation stays free to
  name the trap; the behavioural half of the contract lives in
  `publisher_outcome_test.exs`.
  """
  use ExUnit.Case, async: true

  @moduletag :core

  @source Path.expand("../../../lib/bot_army_library_runtime/intent/publisher.ex", __DIR__)

  # Only executable text has to be clean. Comments and moduledocs must be free to
  # name the trap — otherwise documenting it trips the very lint that documents it
  # (that is how this test failed on 2026-10-13, matching its own explanation).
  defp code_only(source) do
    source
    |> String.split("\n")
    |> Enum.map(&Regex.replace(~r/\s#.*$/, &1, ""))
    |> Enum.join("\n")
  end

  setup do
    %{code: code_only(File.read!(@source)), source: File.read!(@source)}
  end

  test "the veto window never hard-matches Gnat.sub/3", %{code: code} do
    refute code =~ ":ok = Gnat.sub",
           "Gnat.sub/3 returns {:ok, sid}; a hard match crashes the publisher"
  end

  test "the veto window unsubscribes by sid, not by subject", %{code: code} do
    refute code =~ "Gnat.unsub(conn, veto_subj)",
           "Gnat.unsub/3 takes the sid; passing the subject leaks the veto subscription"
  end

  test "the veto window uses the runtime's non-fatal wrappers", %{source: source} do
    assert source =~ "Connection.safe_sub(conn, self(), veto_subj)"
    assert source =~ "Connection.unsub(conn, sid)"
  end

  test "the veto window maps its result through the tested pure function", %{code: code} do
    # The bare-atom `case` this replaced was unreachable and unexecuted; the
    # behavioural coverage lives in publisher_outcome_test.exs.
    assert code =~ "veto_outcome(result, intent_id, endorsements)"
    refute code =~ "case result do\n              :vetoed"
  end
end
