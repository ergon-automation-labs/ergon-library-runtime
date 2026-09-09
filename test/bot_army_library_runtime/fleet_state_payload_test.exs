defmodule BotArmyRuntime.NATS.PublisherGuardTest do
  @moduledoc """
  Pins the publish/3 payload contract the FleetStatePublisher tripped over:
  the guard is is_map(payload) — a pre-encoded JSON BINARY raises
  FunctionClauseError (2026-09-09: FleetStatePublisher called publish with
  a Jason.encode!-ed string every interval; rescued + logged as
  "[FleetStatePublisher] Exception publishing state").

  In :test env there is no live NATS connection — a well-formed map publish
  returns {:error, reason} (connection unavailable), it must NOT raise.
  """

  use ExUnit.Case, async: false

  alias BotArmyLibraryRuntime.NATS.Publisher

  describe "publish/3 payload guard contract" do
    test "map payload is accepted by the guard (error from missing conn, not a raise)" do
      # The exact payload shape FleetStatePublisher.build_state_payload
      # produces — must pass the is_map guard.
      payload = %{
        "name" => "test_bot",
        "version" => "0.0.0",
        "pid" => System.pid(),
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      result = Publisher.publish("bot_army.test_bot.state", payload)
      assert match?({:error, _}, result) or match?({:ok, _}, result)
    end

    test "binary payload raises FunctionClauseError — callers must pass maps" do
      assert_raise FunctionClauseError, fn ->
        Publisher.publish("bot_army.test_bot.state", Jason.encode!(%{"a" => 1}))
      end
    end
  end
end