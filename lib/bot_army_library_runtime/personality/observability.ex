defmodule BotArmyLibraryRuntime.Personality.Observability do
  @moduledoc """
  Telemetry and structured logging for soul (tenant DB) and pulse (NATS) paths.

  ## Telemetry event names

  All use the `[:bot_army, :personality, ...]` prefix for PromEx and ad-hoc handlers.

  | Event | Measurements | Metadata |
  |-------|--------------|----------|
  | `[:bot_army, :personality, :soul, :get]` | `duration` (native), `count` | `outcome`, `bot_id`, `tenant_id`, optional `soul_version` |
  | `[:bot_army, :personality, :soul, :upsert]` | `duration` (native), `count` | `outcome`, `bot_id`, `tenant_id`, optional `soul_version` |
  | `[:bot_army, :personality, :soul, :publish]` | `count` | `outcome`, `bot_id`, `tenant_id`, optional `error` |
  | `[:bot_army, :personality, :heartbeat, :get]` | `duration` (native), `count` | `outcome`, `service`, `tenant_id`, optional `status` |
  | `[:bot_army, :personality, :heartbeat, :record]` | `duration` (native), `count` | `outcome`, `service`, `tenant_id`, optional `status` |
  | `[:bot_army, :personality, :memory, :append]` | `duration` (native), `count` | `outcome`, `scope`, `tenant_id`, `kind` |
  | `[:bot_army, :personality, :memory, :list]` | `duration` (native), `count` | `outcome`, `scope`, `tenant_id`, `kind`, `entry_count` |
  | `[:bot_army, :personality, :memory, :clear]` | `duration` (native), `count` | `outcome`, `scope`, `tenant_id`, optional `kind` |
  | `[:bot_army, :personality, :pulse, :publish]` | `count` | `outcome`, `bot_id`, `tenant_id`, `subject`, optional `error` |

  Attach handlers with `:telemetry.attach/4` or scrape via `BotArmyLibraryRuntime.Metrics.PromExPlugin`.
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

  @type heartbeat_outcome :: :found | :missing | :error
  @type heartbeat_record_outcome :: :ok | :error | :skipped

  @doc false
  @spec heartbeat_get_complete(
          start :: integer(),
          service :: String.t(),
          tenant_id :: String.t(),
          heartbeat_outcome(),
          status :: String.t() | nil
        ) :: :ok
  def heartbeat_get_complete(start, service, tenant_id, outcome, status \\ nil)
      when is_integer(start) and is_binary(service) and outcome in [:found, :missing, :error] do
    duration = System.monotonic_time() - start

    meta =
      %{service: service, tenant_id: tenant_id, outcome: outcome}
      |> maybe_put(:status, status)

    :telemetry.execute(
      [:bot_army, :personality, :heartbeat, :get],
      %{duration: duration, count: 1},
      meta
    )

    log_heartbeat_get(meta)
    :ok
  end

  defp log_heartbeat_get(%{outcome: :found} = m) do
    Logger.debug(
      "[Personality] Heartbeat row read service=#{m.service} tenant_id=#{m.tenant_id} status=#{m[:status]}"
    )
  end

  defp log_heartbeat_get(%{outcome: :missing} = m) do
    Logger.debug(
      "[Personality] Heartbeat row missing service=#{m.service} tenant_id=#{m.tenant_id}"
    )
  end

  defp log_heartbeat_get(%{outcome: :error} = m) do
    Logger.warning(
      "[Personality] Heartbeat query failed service=#{m.service} tenant_id=#{m.tenant_id}"
    )
  end

  @doc false
  @spec heartbeat_record_complete(
          start :: integer(),
          service :: String.t(),
          tenant_id :: String.t(),
          heartbeat_record_outcome(),
          status :: String.t() | nil
        ) :: :ok
  def heartbeat_record_complete(start, service, tenant_id, outcome, status \\ nil)
      when is_integer(start) and outcome in [:ok, :error, :skipped] do
    duration = System.monotonic_time() - start

    meta =
      %{service: service, tenant_id: tenant_id, outcome: outcome}
      |> maybe_put(:status, status)

    :telemetry.execute(
      [:bot_army, :personality, :heartbeat, :record],
      %{duration: duration, count: 1},
      meta
    )

    case outcome do
      :ok ->
        Logger.debug(
          "[Personality] Heartbeat persisted service=#{service} tenant_id=#{tenant_id} status=#{inspect(status)}"
        )

      :skipped ->
        Logger.debug(
          "[Personality] Heartbeat persistence skipped (repo unavailable) service=#{service} tenant_id=#{tenant_id}"
        )

      :error ->
        Logger.warning(
          "[Personality] Heartbeat persistence failed service=#{service} tenant_id=#{tenant_id} status=#{inspect(status)}"
        )
    end

    :ok
  end

  @type memory_list_outcome :: :found | :missing | :error
  @type memory_write_outcome :: :ok | :error | :skipped

  @doc false
  @spec memory_append_complete(
          start :: integer(),
          scope :: String.t(),
          tenant_id :: String.t(),
          memory_write_outcome(),
          kind :: String.t()
        ) :: :ok
  def memory_append_complete(start, scope, tenant_id, outcome, kind)
      when is_integer(start) and outcome in [:ok, :error, :skipped] do
    duration = System.monotonic_time() - start

    :telemetry.execute(
      [:bot_army, :personality, :memory, :append],
      %{duration: duration, count: 1},
      %{scope: scope, tenant_id: tenant_id, outcome: outcome, kind: kind}
    )

    case outcome do
      :ok ->
        Logger.debug(
          "[Personality] Memory appended scope=#{scope} tenant_id=#{tenant_id} kind=#{kind}"
        )

      :skipped ->
        Logger.debug(
          "[Personality] Memory append skipped (repo unavailable) scope=#{scope} tenant_id=#{tenant_id}"
        )

      :error ->
        Logger.warning(
          "[Personality] Memory append failed scope=#{scope} tenant_id=#{tenant_id} kind=#{kind}"
        )
    end

    :ok
  end

  @doc false
  @spec memory_list_complete(
          start :: integer(),
          scope :: String.t(),
          tenant_id :: String.t(),
          memory_list_outcome(),
          kind :: String.t(),
          entry_count :: non_neg_integer()
        ) :: :ok
  def memory_list_complete(start, scope, tenant_id, outcome, kind, entry_count)
      when is_integer(start) and outcome in [:found, :missing, :error] do
    duration = System.monotonic_time() - start

    :telemetry.execute(
      [:bot_army, :personality, :memory, :list],
      %{duration: duration, count: 1},
      %{
        scope: scope,
        tenant_id: tenant_id,
        outcome: outcome,
        kind: kind,
        entry_count: entry_count
      }
    )

    :ok
  end

  @doc false
  @spec memory_clear_complete(
          start :: integer(),
          scope :: String.t(),
          tenant_id :: String.t(),
          memory_write_outcome(),
          kind :: String.t() | nil
        ) :: :ok
  def memory_clear_complete(start, scope, tenant_id, outcome, kind \\ nil)
      when is_integer(start) and outcome in [:ok, :error, :skipped] do
    duration = System.monotonic_time() - start

    meta =
      %{scope: scope, tenant_id: tenant_id, outcome: outcome}
      |> maybe_put(:kind, kind)

    :telemetry.execute(
      [:bot_army, :personality, :memory, :clear],
      %{duration: duration, count: 1},
      meta
    )

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
