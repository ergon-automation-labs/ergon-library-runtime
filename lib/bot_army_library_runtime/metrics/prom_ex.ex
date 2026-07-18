defmodule BotArmyLibraryRuntime.PromEx do
  @moduledoc """
  PromEx module for Bot Army metrics collection.

  Collects NATS, BEAM, and Ecto metrics via PromEx plugins.
  """

  use PromEx, otp_app: :bot_army_runtime

  @impl true
  def plugins do
    [
      BotArmyLibraryRuntime.Metrics.PromExPlugin,
      PromEx.Plugins.Beam
    ]
  end

  @impl true
  def dashboards do
    [{:prom_ex, :"beam.json"}]
  end
end
