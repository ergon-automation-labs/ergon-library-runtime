defmodule BotArmyRuntime.SynapseHealth do
  @moduledoc """
  Publishes Synapse hydration `system.health` heartbeats.

  Synapse treats `system.health` as stale after about 90 seconds; bots should emit
  a heartbeat about every 30 seconds even when `bot.<service>.pulse` (or domain
  pulses) are much slower. See `docs/SYNAPSE_CONTEXT_HYDRATION_CONTRACT.md`.
  """

  alias BotArmyRuntime.NATS.Publisher
  alias BotArmyRuntime.Tenant

  @doc """
  Wall-clock uptime in seconds for the running BEAM node (same semantics as `:erlang.statistics/1`).
  """
  def uptime_seconds do
    {ms, _} = :erlang.statistics(:wall_clock)
    div(ms, 1000)
  end

  @doc """
  Map legacy pulse `health_signal` strings to `system.health` payload `status`.
  """
  def signal_to_status(s) when is_atom(s), do: s |> Atom.to_string() |> signal_to_status()

  def signal_to_status("nominal"), do: "healthy"
  def signal_to_status("degraded"), do: "degraded"
  def signal_to_status("critical"), do: "unhealthy"
  def signal_to_status("healthy"), do: "healthy"
  def signal_to_status("unhealthy"), do: "unhealthy"
  def signal_to_status(_), do: "unknown"

  @doc """
  Publish one `system.health` envelope on subject `system.health`.

  ## Required

    * `:source` — envelope `source` (e.g. `\"bot_army_gtd\"`)
    * `:service` — payload `service` (e.g. `\"gtd\"`)

  ## Optional

    * `:tenant_id` — default `Tenant.default_tenant_id/0`
    * `:status` — overrides `:health_signal` when set
    * `:health_signal` — `\"nominal\"` | `\"degraded\"` | `\"critical\"` (default `\"nominal\"`)
    * `:uptime_seconds` — default from `uptime_seconds/0`
    * `:last_event_age_ms` — default `0`
    * `:sequence`, `:dedupe_key`, `:schema_version`
  """
  def publish(opts) when is_list(opts) do
    source = Keyword.fetch!(opts, :source)
    service = Keyword.fetch!(opts, :service)
    tenant_id = Keyword.get(opts, :tenant_id, Tenant.default_tenant_id())

    status =
      case Keyword.get(opts, :status) do
        nil -> signal_to_status(Keyword.get(opts, :health_signal, "nominal"))
        s when is_binary(s) -> s
      end

    uptime = Keyword.get(opts, :uptime_seconds, uptime_seconds())
    last_age = Keyword.get(opts, :last_event_age_ms, 0)

    payload =
      %{
        "service" => service,
        "status" => status,
        "uptime_seconds" => uptime,
        "last_event_age_ms" => last_age
      }
      |> maybe_put("dedupe_key", Keyword.get(opts, :dedupe_key))
      |> maybe_put("sequence", Keyword.get(opts, :sequence))

    envelope = %{
      "event_id" => Ecto.UUID.generate(),
      "event" => "system.health",
      "schema_version" => Keyword.get(opts, :schema_version, "1.0"),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => source,
      "tenant_id" => tenant_id,
      "payload" => payload
    }

    Publisher.publish("system.health", envelope)
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
