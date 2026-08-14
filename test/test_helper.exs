ExUnit.configure(exclude: [:integration, :load, :nats_live])
ExUnit.start()

# Only configure Ecto sandbox if the Repo is available
# (bot_army_runtime doesn't start its own Repo — each bot does)
if Code.ensure_loaded?(BotArmyLibraryRuntime.Ecto.Repo) and
     function_exported?(BotArmyLibraryRuntime.Ecto.Repo, :__adapter__, 0) do
  try do
    Ecto.Adapters.SQL.Sandbox.mode(BotArmyLibraryRuntime.Ecto.Repo, :auto)
  rescue
    _ -> :ok
  end
end
