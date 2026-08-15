defmodule BotArmyLibraryRuntime.Ecto.RuntimeDbConfigTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyLibraryRuntime.Ecto.RuntimeDbConfig

  @env_vars ~w(
    BOT_ARMY_TESTBOT_DB_NAME BOT_ARMY_TESTBOT_DB_HOST BOT_ARMY_TESTBOT_DB_PORT
    BOT_ARMY_TESTBOT_DB_USER BOT_ARMY_TESTBOT_DB_PASSWORD BOT_ARMY_TESTBOT_POOL_SIZE
    DATABASE_NAME DATABASE_HOST DATABASE_PORT DATABASE_USER DATABASE_PASSWORD BOT_POOL_SIZE
  )

  setup do
    originals = Map.new(@env_vars, &{&1, System.get_env(&1)})
    Enum.each(@env_vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(originals, fn
        {var, nil} -> System.delete_env(var)
        {var, val} -> System.put_env(var, val)
      end)
    end)

    :ok
  end

  describe "resolve/2" do
    test "falls back to hardcoded defaults when nothing is set" do
      assert RuntimeDbConfig.resolve("BOT_ARMY_TESTBOT") == [
               database: "bot_army_testbot",
               hostname: "localhost",
               port: 5432,
               username: "postgres",
               password: "postgres"
             ]
    end

    test "the defaults: keyword overrides the hardcoded fallback" do
      result = RuntimeDbConfig.resolve("BOT_ARMY_TESTBOT", database: "custom_db", port: 30003)
      assert result[:database] == "custom_db"
      assert result[:port] == 30003
    end

    test "generic DATABASE_* wins over the hardcoded fallback" do
      System.put_env("DATABASE_HOST", "generic-host")
      System.put_env("DATABASE_PORT", "5433")

      result = RuntimeDbConfig.resolve("BOT_ARMY_TESTBOT")
      assert result[:hostname] == "generic-host"
      assert result[:port] == 5433
    end

    test "bot-specific BOT_ARMY_TESTBOT_DB_* wins over generic DATABASE_*" do
      System.put_env("DATABASE_HOST", "generic-host")
      System.put_env("BOT_ARMY_TESTBOT_DB_HOST", "specific-host")

      result = RuntimeDbConfig.resolve("BOT_ARMY_TESTBOT")
      assert result[:hostname] == "specific-host"
    end

    test "each field resolves its own tier independently" do
      # Regression case for the dispatcher bug: a bot-specific override for
      # one field must not be required for other fields to also check their
      # own bot-specific tier.
      System.put_env("BOT_ARMY_TESTBOT_DB_NAME", "only_name_overridden")
      System.put_env("DATABASE_HOST", "generic-host")

      result = RuntimeDbConfig.resolve("BOT_ARMY_TESTBOT")
      assert result[:database] == "only_name_overridden"
      assert result[:hostname] == "generic-host"
    end

    test "port is always an integer regardless of which tier resolved it" do
      assert RuntimeDbConfig.resolve("BOT_ARMY_TESTBOT")[:port] == 5432

      System.put_env("DATABASE_PORT", "5433")
      assert RuntimeDbConfig.resolve("BOT_ARMY_TESTBOT")[:port] == 5433

      System.put_env("BOT_ARMY_TESTBOT_DB_PORT", "5434")
      assert RuntimeDbConfig.resolve("BOT_ARMY_TESTBOT")[:port] == 5434
    end
  end

  describe "pool_size/2" do
    test "falls back to the given default" do
      assert RuntimeDbConfig.pool_size("BOT_ARMY_TESTBOT", 7) == 7
    end

    test "BOT_POOL_SIZE (fleet-wide convention) wins over the default" do
      System.put_env("BOT_POOL_SIZE", "12")
      assert RuntimeDbConfig.pool_size("BOT_ARMY_TESTBOT", 7) == 12
    end

    test "bot-specific POOL_SIZE wins over BOT_POOL_SIZE" do
      System.put_env("BOT_POOL_SIZE", "12")
      System.put_env("BOT_ARMY_TESTBOT_POOL_SIZE", "20")
      assert RuntimeDbConfig.pool_size("BOT_ARMY_TESTBOT", 7) == 20
    end

    test "returns an integer" do
      System.put_env("BOT_POOL_SIZE", "9")
      assert RuntimeDbConfig.pool_size("BOT_ARMY_TESTBOT", 7) === 9
    end
  end
end
