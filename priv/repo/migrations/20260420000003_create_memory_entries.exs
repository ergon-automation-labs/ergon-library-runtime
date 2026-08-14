defmodule BotArmyRuntime.Repo.Migrations.CreateMemoryEntries do
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
    create table(:memory_entries, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:scope, :string, null: false)
      add(:tenant_id, :binary_id, null: false)
      add(:user_id, :string)
      add(:source, :string)
      add(:kind, :string, null: false, default: "thought")
      add(:payload, :jsonb, null: false, default: "{}")
      add(:recorded_at, :utc_datetime, null: false)

      timestamps(type: :utc_datetime)
    end

    create(index(:memory_entries, [:scope]))
    create(index(:memory_entries, [:tenant_id]))
    create(index(:memory_entries, [:kind]))
    create(index(:memory_entries, [:scope, :tenant_id, :kind, :recorded_at]))
  end
end
