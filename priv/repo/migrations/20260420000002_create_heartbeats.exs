defmodule BotArmyRuntime.Repo.Migrations.CreateHeartbeats do
  @moduledoc """
  TEMPLATE MIGRATION — do not run from bot_army_runtime.

  bot_army_runtime is a shared library with no database of its own.
  Each bot that uses `BotArmy.Heartbeat` must copy this migration into its own
  `priv/repo/migrations/` directory, renaming the module to match its namespace:

      defmodule BotArmyGtd.Repo.Migrations.CreateHeartbeats do
        # ... same content ...
      end

  Then run `mix ecto.migrate` in that bot.
  """

  use Ecto.Migration

  def change do
    execute("CREATE EXTENSION IF NOT EXISTS \"uuid-ossp\"")

    create table(:heartbeats, primary_key: false) do
      add(:id, :binary_id,
        primary_key: true,
        null: false,
        default: fragment("uuid_generate_v4()")
      )

      add(:bot_id, :string, null: false)
      add(:service, :string, null: false)
      add(:tenant_id, :binary_id, null: false)
      add(:source, :string, null: false)
      add(:status, :string, null: false)
      add(:uptime_seconds, :integer)
      add(:last_event_age_ms, :integer)
      add(:sequence, :integer)
      add(:payload, :jsonb, null: false, default: "{}")
      add(:recorded_at, :utc_datetime, null: false)

      timestamps(type: :utc_datetime)
    end

    create(index(:heartbeats, [:bot_id]))
    create(index(:heartbeats, [:tenant_id]))
    create(index(:heartbeats, [:service]))

    create(
      unique_index(:heartbeats, [:service, :tenant_id], name: :heartbeats_service_tenant_unique)
    )
  end
end
