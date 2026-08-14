defmodule BotArmyRuntime.Repo.Migrations.CreateSouls do
  @moduledoc """
  Shared runtime migration — runs automatically via
  `BotArmyLibraryRuntime.Ecto.MigrationRunner`, tracked in
  `runtime_schema_migrations`.

  Do NOT copy this into a bot's own `priv/repo/migrations/`. The runner applies
  it to every bot database before the bot's own migrations, so a copy either
  fails on an existing table or is silently skipped as a version collision.
  """

  use Ecto.Migration

  def change do
    create table(:souls, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:bot_id, :string, null: false)
      add(:tenant_id, :binary_id, null: false)
      add(:config, :jsonb, null: false, default: "{}")
      add(:version, :integer, null: false, default: 1)
      add(:active, :boolean, null: false, default: true)

      timestamps(type: :utc_datetime)
    end

    create(index(:souls, [:bot_id]))
    create(index(:souls, [:tenant_id]))
    create(index(:souls, [:bot_id, :tenant_id], unique: true, name: :souls_bot_tenant_unique))
  end
end
