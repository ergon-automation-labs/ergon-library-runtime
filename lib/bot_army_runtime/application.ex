defmodule BotArmyRuntime.Application do
  @moduledoc """
  Supervision tree for BotArmyRuntime.

  Starts:
  - Ecto Repo (database connection pool)
  - NATS Connection (message bus connection)
  - Telemetry handlers
  """

  use Application

  @impl true
  def start(_type, _args) do
    # Note: BotArmyRuntime.Ecto.Repo is NOT started here.
    # Each bot service (bot_army_gtd, bot_army_llm, etc.) defines its own Repo
    # and is responsible for starting it. This keeps database configuration
    # independent per bot and allows tests to run without database errors.

    children = [
      # Telemetry handlers for observability
      {BotArmyRuntime.Telemetry, []}

      # NATS connection is started conditionally based on application needs
      # See NATS.Connection module for details
    ]

    opts = [strategy: :one_for_one, name: BotArmyRuntime.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
