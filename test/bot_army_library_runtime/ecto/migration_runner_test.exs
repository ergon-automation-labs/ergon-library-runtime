defmodule BotArmyLibraryRuntime.Ecto.MigrationRunnerTest do
  use ExUnit.Case, async: true
  @moduletag :core

  alias BotArmyLibraryRuntime.Ecto.MigrationRunner

  setup do
    path =
      Path.join(System.tmp_dir!(), "migration_runner_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    {:ok, path: path}
  end

  defp touch(path, name), do: File.write!(Path.join(path, name), "")

  describe "migration_versions/1" do
    test "parses versions and sorts ascending", %{path: path} do
      touch(path, "20260512000002_create_intent_threshold_adjustments.exs")
      touch(path, "20260420000001_create_souls.exs")
      touch(path, "20260523000001_create_heartbeats_shared.exs")

      assert MigrationRunner.migration_versions(path) == [
               20_260_420_000_001,
               20_260_512_000_002,
               20_260_523_000_001
             ]
    end

    test "ignores non-migration files", %{path: path} do
      touch(path, "20260420000001_create_souls.exs")
      touch(path, "README.md")
      touch(path, "notes.txt")
      touch(path, "no_leading_version.exs")

      assert MigrationRunner.migration_versions(path) == [20_260_420_000_001]
    end

    test "returns [] for a directory with no migrations", %{path: path} do
      assert MigrationRunner.migration_versions(path) == []
    end
  end

  describe "colliding_migrations/2" do
    test "reports a bot migration sharing a runtime version", %{path: path} do
      # The bot_army_library_learning failure: the bot's add_tenant_and_user_id
      # was numbered the same as runtime's create_souls, so it was recorded as
      # applied without running and the next migration hit a missing column.
      touch(path, "20260420000001_add_tenant_and_user_id.exs")
      touch(path, "20260421000001_create_skills_and_actions.exs")

      assert MigrationRunner.colliding_migrations(path, [20_260_420_000_001]) ==
               [{20_260_420_000_001, "20260420000001_add_tenant_and_user_id.exs"}]
    end

    test "returns [] when no versions overlap", %{path: path} do
      touch(path, "20260813000001_add_tenant_and_user_id.exs")

      assert MigrationRunner.colliding_migrations(path, [20_260_420_000_001]) == []
    end

    test "reports every collision, sorted", %{path: path} do
      touch(path, "20260512000001_create_intent_outcomes.exs")
      touch(path, "20260420000001_create_souls.exs")
      touch(path, "20260813000001_safe.exs")

      assert MigrationRunner.colliding_migrations(path, [
               20_260_512_000_001,
               20_260_420_000_001
             ]) == [
               {20_260_420_000_001, "20260420000001_create_souls.exs"},
               {20_260_512_000_001, "20260512000001_create_intent_outcomes.exs"}
             ]
    end

    test "returns [] when the runtime set is empty", %{path: path} do
      touch(path, "20260420000001_create_souls.exs")

      assert MigrationRunner.colliding_migrations(path, []) == []
    end
  end
end
