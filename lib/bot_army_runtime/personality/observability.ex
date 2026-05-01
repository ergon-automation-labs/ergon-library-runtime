defmodule BotArmyRuntime.Personality.Observability do
  @moduledoc """
  Telemetry and structured logging for soul (tenant DB) and pulse (NATS) paths.

  ## Telemetry event names

  All use the `[:bot_army, :personality, ...]` prefix for PromEx and ad-hoc handlers.

  | Event | Measurements | Metadata |
  |-------|--------------|----------|
  | `[:bot_army, :personality, :soul, :get]` | `duration` (native), `count` | `outcome`, `bot_id`, `tenant_id`, optional `soul_version` |
  | `[:bot_army, :personality, :soul, :upsert]` | `duration` (native), `count` | `outcome`, `bot_id`, `tenant_id`, optional `soul_version` |
  | `[:bot_army, :personality, :soul, :publish]` | `count` | `outcome`, `bot_id`, `tenant_id`, optional `error` |
  | `[:bot_army, :personality, :pulse, :publish]` | `count` | `outcome`, `bot_id`, `tenant_id`, `subject`, optional `error` |

  Attach handlers with `:telemetry.attach/4` or scrape via `BotArmyRuntime.Metrics.PromExPlugin`.
  """

  require Logger

  @type soul_outcome :: :found | :missing | :error

  @doc false
  @spec soul_get_complete(
          start :: integer(),
          bot_id :: String.t(),
          tenant_id :: String.t(),
          soul_outcome(),
          soul_version :: pos_integer() | nil
        ) :: :ok
  def soul_get_complete(start, bot_id, tenant_id, outcome, soul_version \\ nil)
      when is_integer(start) and is_binary(bot_id) and outcome in [:found, :missing, :error] do
    duration = System.monotonic_time() - start

    meta =
      %{bot_id: bot_id, tenant_id: tenant_id, outcome: outcome}
      |> maybe_put(:soul_version, soul_version)

    :telemetry.execute(
      [:bot_army, :personality, :soul, :get],
      %{duration: duration, count: 1},
      meta
    )

    log_soul_get(meta)
    :ok
  end

  defp log_soul_get(%{outcome: :found} = m) do
    Logger.debug(
      "[Personality] Soul row read bot_id=#{m.bot_id} tenant_id=#{m.tenant_id} soul_version=#{m[:soul_version]}"
    )
  end

  defp log_soul_get(%{outcome: :missing} = m) do
    Logger.debug(
      "[Personality] Soul row missing (no persistence row yet) bot_id=#{m.bot_id} tenant_id=#{m.tenant_id}"
    )
  end

  defp log_soul_get(%{outcome: :error} = m) do
    Logger.warning("[Personality] Soul query failed bot_id=#{m.bot_id} tenant_id=#{m.tenant_id}")
  end

  @doc false
  @spec soul_upsert_complete(integer(), String.t(), String.t(), :ok | :error, pos_integer() | nil) ::
          :ok
  def soul_upsert_complete(start, bot_id, tenant_id, outcome, soul_version)
      when is_integer(start) and outcome in [:ok, :error] do
    duration = System.monotonic_time() - start

    meta =
      %{bot_id: bot_id, tenant_id: tenant_id, outcome: outcome}
      |> maybe_put(:soul_version, soul_version)

    :telemetry.execute(
      [:bot_army, :personality, :soul, :upsert],
      %{duration: duration, count: 1},
      meta
    )

    case outcome do
      :ok ->
        Logger.info(
          "[Personality] Soul upsert persisted bot_id=#{bot_id} tenant_id=#{tenant_id} soul_version=#{inspect(soul_version)}"
        )

      :error ->
        Logger.warning("[Personality] Soul upsert failed bot_id=#{bot_id} tenant_id=#{tenant_id}")
    end

    :ok
  end

  @doc false
  @spec soul_publish(String.t(), String.t(), :ok | :error, String.t() | nil) :: :ok
  def soul_publish(bot_id, tenant_id, outcome, error_message \\ nil)
      when outcome in [:ok, :error] do
    meta =
      %{bot_id: bot_id, tenant_id: tenant_id, outcome: outcome}
      |> maybe_put(:error, error_message)

    :telemetry.execute([:bot_army, :personality, :soul, :publish], %{count: 1}, meta)

    case outcome do
      :ok ->
        Logger.info(
          "[Personality] Soul snapshot published to NATS bot_id=#{bot_id} tenant_id=#{tenant_id}"
        )

      :error ->
        Logger.warning(
          "[Personality] Soul NATS publish failed bot_id=#{bot_id} tenant_id=#{tenant_id} error=#{inspect(error_message)}"
        )
    end

    :ok
  end

  @doc false
  @spec pulse_publish(String.t(), String.t(), String.t(), :ok | :error, String.t() | nil) :: :ok
  def pulse_publish(bot_id, tenant_id, subject, outcome, error_message \\ nil)
      when outcome in [:ok, :error] do
    meta =
      %{bot_id: bot_id, tenant_id: tenant_id, subject: subject, outcome: outcome}
      |> maybe_put(:error, error_message)

    :telemetry.execute([:bot_army, :personality, :pulse, :publish], %{count: 1}, meta)

    Logger.debug(
      "[Personality] Pulse publish bot_id=#{bot_id} tenant_id=#{tenant_id} subject=#{subject} outcome=#{outcome}"
    )

    if outcome == :error do
      Logger.warning(
        "[Personality] Pulse NATS publish failed bot_id=#{bot_id} tenant_id=#{tenant_id} subject=#{subject} error=#{inspect(error_message)}"
      )
    end

    :ok
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
