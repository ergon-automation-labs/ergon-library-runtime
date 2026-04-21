defmodule BotArmyRuntime.TelemetryTest do
  use ExUnit.Case, async: false
  @moduletag :core

  import ExUnit.CaptureLog

  describe "handle_ecto_query/4" do
    test "does not log for fast queries" do
      log =
        capture_log(fn ->
          BotArmyRuntime.Telemetry.handle_ecto_query(
            [:ecto, :repo, :query],
            %{total_time: 500_000},
            %{repo: TestRepo, source: "tasks"},
            nil
          )
        end)

      assert log == ""
    end

    test "logs warning for slow queries (>1s)" do
      log =
        capture_log([level: :warning], fn ->
          BotArmyRuntime.Telemetry.handle_ecto_query(
            [:ecto, :repo, :query],
            %{total_time: 1_500_000},
            %{repo: TestRepo, source: "tasks"},
            nil
          )
        end)

      assert log =~ "Slow query"
    end
  end

  describe "handle_ecto_error/4" do
    test "logs error for query failures" do
      log =
        capture_log([level: :error], fn ->
          BotArmyRuntime.Telemetry.handle_ecto_error(
            [:ecto, :repo, :query, :exception],
            %{total_time: 100_000},
            %{repo: TestRepo, source: "tasks", error: %RuntimeError{message: "boom"}},
            nil
          )
        end)

      assert log =~ "Query failed"
    end
  end

  describe "handle_nats_publish/4" do
    test "logs debug for successful publish" do
      Logger.configure(level: :debug)

      log =
        capture_log(fn ->
          BotArmyRuntime.Telemetry.handle_nats_publish(
            [:nats, :pub],
            %{duration: 50_000},
            %{subject: "gtd.task.created"},
            nil
          )
        end)

      Logger.configure(level: :warning)
      assert log =~ "Message published"
    end

    test "handles total_time fallback when duration is missing" do
      Logger.configure(level: :debug)

      log =
        capture_log(fn ->
          BotArmyRuntime.Telemetry.handle_nats_publish(
            [:nats, :pub],
            %{total_time: 50_000},
            %{subject: "gtd.task.created"},
            nil
          )
        end)

      Logger.configure(level: :warning)
      assert log =~ "Message published"
    end

    test "handles missing both duration and total_time" do
      Logger.configure(level: :debug)

      log =
        capture_log(fn ->
          BotArmyRuntime.Telemetry.handle_nats_publish(
            [:nats, :pub],
            %{},
            %{subject: "gtd.task.created"},
            nil
          )
        end)

      Logger.configure(level: :warning)
      assert log =~ "Message published"
    end
  end

  describe "handle_nats_error/4" do
    test "logs error for failed publish" do
      log =
        capture_log([level: :error], fn ->
          BotArmyRuntime.Telemetry.handle_nats_error(
            [:nats, :pub, :exception],
            %{duration: 50_000},
            %{subject: "gtd.task.created", error: %RuntimeError{message: "connection lost"}},
            nil
          )
        end)

      assert log =~ "Publish failed"
    end
  end

  describe "Sentry integration" do
    test "handle_sentry_error is a no-op when Sentry DSN is not configured" do
      result =
        try do
          BotArmyRuntime.Telemetry.handle_sentry_error(
            [:ecto, :repo, :query, :exception],
            %{},
            %{error: %RuntimeError{message: "test"}, source: "tasks"},
            nil
          )

          :ok
        rescue
          _ -> :error
        end

      assert result == :ok
    end

    test "handle_sentry_error handles missing error in metadata gracefully" do
      result =
        try do
          BotArmyRuntime.Telemetry.handle_sentry_error(
            [:nats, :pub, :exception],
            %{},
            %{subject: "test.subject"},
            nil
          )

          :ok
        rescue
          _ -> :error
        end

      assert result == :ok
    end
  end
end
