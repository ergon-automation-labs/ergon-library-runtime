defmodule BotArmyLibraryRuntime.TimestampTest do
  use ExUnit.Case, async: true

  alias BotArmyLibraryRuntime.Timestamp

  doctest BotArmyLibraryRuntime.Timestamp

  describe "utc_iso8601/1 names the zone" do
    test "a naive Ecto timestamp column is read as UTC" do
      assert Timestamp.utc_iso8601(~N[2026-10-08 00:46:52]) == "2026-10-08T00:46:52Z"
    end

    test "a DateTime is shifted to UTC, so the name stays true" do
      {:ok, paris, _offset} = DateTime.from_iso8601("2026-10-08T02:46:52+02:00")

      assert Timestamp.utc_iso8601(paris) == "2026-10-08T00:46:52Z"
    end

    test "the same instant written both ways produces the same string" do
      {:ok, as_datetime, _offset} = DateTime.from_iso8601("2026-10-08T00:46:52Z")

      assert Timestamp.utc_iso8601(~N[2026-10-08 00:46:52]) ==
               Timestamp.utc_iso8601(as_datetime)
    end

    test "microseconds a store kept are not silently dropped" do
      assert Timestamp.utc_iso8601(~N[2026-10-08 00:46:52.123456]) ==
               "2026-10-08T00:46:52.123456Z"
    end
  end

  describe "the reader this exists for" do
    # This is the whole point of the module, and the reason it is a deep one: the
    # consumer's tolerance must never be the only thing standing between the two sides.
    # Assert the property from the READER's side, so reverting the producer fails here.
    test "DateTime.from_iso8601/1 can read back what we write" do
      written = Timestamp.utc_iso8601(~N[2026-10-08 00:46:52])

      assert {:ok, read_back, 0} = DateTime.from_iso8601(written)
      assert DateTime.to_iso8601(read_back) == written
    end

    test "the shape this module replaces is refused, which is why it exists" do
      zone_less = NaiveDateTime.to_iso8601(~N[2026-10-08 00:46:52])

      assert zone_less == "2026-10-08T00:46:52"
      assert DateTime.from_iso8601(zone_less) == {:error, :missing_offset}
    end
  end

  describe "utc_iso8601_or_nil/1" do
    test "an unset column reaches the wire as nil, not as a string" do
      assert Timestamp.utc_iso8601_or_nil(nil) == nil
      assert Timestamp.utc_iso8601_or_nil(~N[2026-10-08 00:46:52]) == "2026-10-08T00:46:52Z"
    end
  end
end
