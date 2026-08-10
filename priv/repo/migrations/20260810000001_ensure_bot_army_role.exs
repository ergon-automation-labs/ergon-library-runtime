defmodule BotArmyLibraryRuntime.Repo.Migrations.EnsureBotArmyRole do
  use Ecto.Migration

  def up do
    execute("""
    DO $$ BEGIN
      CREATE ROLE bot_army WITH CREATEDB LOGIN PASSWORD 'bot_army_secret';
    EXCEPTION WHEN DUPLICATE_OBJECT THEN
      ALTER ROLE bot_army WITH CREATEDB;
    END $$;
    """)
  end

  def down do
    # Note: We don't drop the role on down to avoid data loss
    # If you need to remove it, do so manually
    :ok
  end
end
