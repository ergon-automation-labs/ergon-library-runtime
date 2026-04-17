ExUnit.start()

# Only configure Ecto sandbox if the Repo is available
# (bot_army_runtime doesn't start its own Repo — each bot does)
if Code.ensure_loaded?(BotArmyRuntime.Ecto.Repo) and
     function_exported?(BotArmyRuntime.Ecto.Repo, :__adapter__, 0) do
  try do
    Ecto.Adapters.SQL.Sandbox.mode(BotArmyRuntime.Ecto.Repo, :auto)
  rescue
    _ -> :ok
  end
end
