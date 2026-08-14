defmodule BotArmyRuntime.Repo.Migrations.CreateIntentOutcomes do
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
    create table(:intent_outcomes, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:bot_name, :string, null: false)
      add(:action, :string, null: false)
      add(:intent_id, :string, null: false)
      add(:decision, :string, null: false)
      add(:outcome, :string)
      add(:outcome_metadata, :jsonb, null: false, default: "{}")
      add(:score, :float)
      add(:reason, :string)
      add(:observed_at, :utc_datetime, null: false)

      timestamps(type: :utc_datetime)
    end

    create(index(:intent_outcomes, [:bot_name]))
    create(index(:intent_outcomes, [:action]))
    create(index(:intent_outcomes, [:intent_id]))
    create(index(:intent_outcomes, [:bot_name, :action]))
    create(index(:intent_outcomes, [:bot_name, :action, :observed_at]))
  end
end
