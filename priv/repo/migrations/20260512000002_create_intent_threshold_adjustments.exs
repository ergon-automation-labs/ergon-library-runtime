defmodule BotArmyRuntime.Repo.Migrations.CreateIntentThresholdAdjustments do
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
    create table(:intent_threshold_adjustments, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:bot_name, :string, null: false)
      add(:action, :string, null: false)
      add(:observation_type, :string, null: false)
      add(:original_weight, :float, null: false)
      add(:adjusted_weight, :float, null: false)
      add(:adjustment_reason, :string)
      add(:source, :string, null: false, default: "reflection")

      timestamps(type: :utc_datetime)
    end

    create(index(:intent_threshold_adjustments, [:bot_name]))
    create(index(:intent_threshold_adjustments, [:bot_name, :action]))
    create(index(:intent_threshold_adjustments, [:bot_name, :action, :observation_type]))
  end
end
