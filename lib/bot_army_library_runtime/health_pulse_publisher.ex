defmodule BotArmyLibraryRuntime.HealthPulsePublisher do
  @moduledoc """
  Periodic `system.health` heartbeat for bots without a bespoke pulse child.

  One shared child spec instead of a per-bot copy (the bridge_lite /
  sre PulsePublisher pattern, generalized):

      children = [
        ...,
        {BotArmyLibraryRuntime.HealthPulsePublisher,
         [app_name: :bot_army_graphify_cache, service: "graphify_cache"]}
      ]

  Emits a `system.health` envelope (via `SynapseHealth.publish/1`) every
  interval so Synapse's ~90s staleness window is never crossed. Under
  :test the child should simply not be started (see the bots' `maybe_add`
  guard) — or started with a long interval, since publishes degrade
  gracefully to {:error, reason} without a NATS connection.
  """

  use GenServer
  require Logger

  alias BotArmyLibraryRuntime.SynapseHealth

  @default_interval_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    app_name = Keyword.fetch!(opts, :app_name)
    service = Keyword.get(opts, :service, default_service(app_name))
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    schedule_pulse(interval)
    {:ok, %{app_name: app_name, service: service, interval: interval, started_at: System.monotonic_time(:second)}}
  end

  @impl true
  def handle_info(:pulse, state) do
    # SynapseHealth.publish/1 takes a KEYWORD LIST (is_list guard) — maps
    # raise FunctionClauseError (bridge_lite's PulsePublisher passed a map
    # and crash-looped on every pulse until 2026-09-09).
    SynapseHealth.publish(
      source: to_string(state.app_name),
      service: state.service,
      health_signal: "nominal",
      version: app_version(state.app_name),
      uptime_seconds: System.monotonic_time(:second) - state.started_at
    )

    schedule_pulse(state.interval)
    {:noreply, state}
  end

  defp default_service(app_name) do
    app_name
    |> to_string()
    |> String.trim_leading("bot_army_")
    |> String.replace_trailing("_bot", "")
  end

  defp app_version(app_name) do
    case Application.spec(app_name, :vsn) do
      nil -> "unknown"
      vsn when is_list(vsn) -> List.to_string(vsn)
      vsn -> to_string(vsn)
    end
  end

  defp schedule_pulse(interval) do
    Process.send_after(self(), :pulse, interval)
  end
end