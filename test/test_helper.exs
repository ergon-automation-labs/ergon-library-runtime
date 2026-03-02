ExUnit.start()

# Start the Ecto sandbox for concurrent test execution
Ecto.Adapters.SQL.Sandbox.mode(BotArmyRuntime.Ecto.Repo, :auto)

# Import test helpers
Code.require_file("support/test_helpers.ex", __DIR__)
