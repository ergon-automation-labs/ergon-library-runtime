defmodule BotArmyLibraryRuntime.NATS.ConnectionServersTest do
  use ExUnit.Case

  @moduletag :nats

  alias BotArmyLibraryRuntime.NATS.Connection

  # Regression guard for a doc/code mismatch that has real deployment
  # consequences: the moduledoc promised NATS_SERVERS / NATS_HOST / NATS_PORT
  # support, but pick_servers/2 read only the :servers option, then the app
  # config, then the built-in default — so a bot whose NATS_PORT the plist set to
  # 4222 still joined whatever broker was baked in at build time.
  #
  # These tests mutate process-wide env vars, so they must not run concurrently
  # with anything that reads them (ExUnit.Case is async: false by default).

  setup do
    saved = %{
      "NATS_SERVERS" => System.get_env("NATS_SERVERS"),
      "NATS_HOST" => System.get_env("NATS_HOST"),
      "NATS_PORT" => System.get_env("NATS_PORT")
    }

    for name <- Map.keys(saved), do: System.delete_env(name)

    on_exit(fn ->
      for {name, value} <- saved do
        case value do
          nil -> System.delete_env(name)
          value -> System.put_env(name, value)
        end
      end
    end)

    :ok
  end

  describe "pick_servers/2" do
    test "an explicit :servers option wins" do
      System.put_env("NATS_PORT", "4222")

      assert Connection.pick_servers([servers: [{"opt", 1111}]], servers: [{"cfg", 2222}]) ==
               [{"opt", 1111}]
    end

    test "app config beats the environment" do
      System.put_env("NATS_PORT", "4222")

      assert Connection.pick_servers([], servers: [{"cfg", 2222}]) == [{"cfg", 2222}]
    end

    test "an empty or malformed config falls through to the environment" do
      System.put_env("NATS_PORT", "4222")

      assert Connection.pick_servers([], []) == [{"localhost", 4222}]
      assert Connection.pick_servers([], servers: []) == [{"localhost", 4222}]
      assert Connection.pick_servers([], servers: nil) == [{"localhost", 4222}]
      assert Connection.pick_servers([servers: :nonsense], []) == [{"localhost", 4222}]
    end

    test "NATS_HOST and NATS_PORT are honoured at runtime" do
      System.put_env("NATS_HOST", "nats.internal")
      System.put_env("NATS_PORT", "4222")

      assert Connection.pick_servers([], []) == [{"nats.internal", 4222}]
    end

    test "NATS_HOST alone keeps the default port" do
      System.put_env("NATS_HOST", "nats.internal")

      assert Connection.pick_servers([], []) == [{"nats.internal", 4223}]
    end

    test "NATS_PORT alone keeps the default host" do
      System.put_env("NATS_PORT", "4222")

      assert Connection.pick_servers([], []) == [{"localhost", 4222}]
    end

    test "with nothing configured the fail-safe dev broker wins" do
      assert Connection.pick_servers([], []) == [{"localhost", 4223}]
      assert Connection.servers_from_env() == nil
    end

    test "a garbage port falls back to the dev broker rather than crashing" do
      System.put_env("NATS_PORT", "not-a-port")

      assert Connection.pick_servers([], []) == [{"localhost", 4223}]
    end
  end

  describe "servers_from_env/0" do
    test "parses a space-separated NATS_SERVERS list and uses the first entry" do
      System.put_env("NATS_SERVERS", "localhost:4222 localhost:14223")

      # Gnat is single-server: only the first entry is used, as documented.
      assert Connection.servers_from_env() == [{"localhost", 4222}]
    end

    test "parses a comma-separated list" do
      System.put_env("NATS_SERVERS", "alpha:4222,beta:4223")

      assert Connection.servers_from_env() == [{"alpha", 4222}]
    end

    test "strips an optional nats:// scheme" do
      System.put_env("NATS_SERVERS", "nats://broker.internal:4222")

      assert Connection.servers_from_env() == [{"broker.internal", 4222}]
    end

    test "a bare host takes the port from NATS_PORT" do
      System.put_env("NATS_SERVERS", "broker.internal")
      System.put_env("NATS_PORT", "4222")

      assert Connection.servers_from_env() == [{"broker.internal", 4222}]
    end

    test "a malformed NATS_SERVERS entry falls back to NATS_HOST/NATS_PORT" do
      System.put_env("NATS_SERVERS", "broker.internal:not-a-port")
      System.put_env("NATS_PORT", "4222")

      assert Connection.servers_from_env() == [{"localhost", 4222}]
    end

    test "an empty NATS_SERVERS is treated as unset" do
      System.put_env("NATS_SERVERS", "   ")
      System.put_env("NATS_PORT", "4222")

      assert Connection.servers_from_env() == [{"localhost", 4222}]
    end

    test "NATS_SERVERS wins over NATS_HOST" do
      System.put_env("NATS_SERVERS", "alpha:4222")
      System.put_env("NATS_HOST", "ignored.internal")
      System.put_env("NATS_PORT", "4223")

      assert Connection.servers_from_env() == [{"alpha", 4222}]
    end
  end
end
