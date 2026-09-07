defmodule BotArmyLibraryRuntime.Telemetry do
  @moduledoc """
  Sets up telemetry handlers for observability across Bot Army services.

  Handles:
  - Ecto query metrics
  - NATS publishing metrics
  - Application-level logging
  - Error tracking via Sentry (when configured)
  """

  use GenServer

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    attach_ecto_handlers()
    attach_nats_handlers()
    attach_retry_handlers()
    attach_error_handlers()

    Logger.info("[Telemetry] Initialized")

    {:ok, %{}}
  end

  defp safe_attach(handler_id, event_name, handler, config) do
    :telemetry.detach(handler_id)
    :telemetry.attach(handler_id, event_name, handler, config)
  end

  defp attach_ecto_handlers do
    safe_attach(
      "ecto-query-logging",
      [:ecto, :repo, :query],
      &__MODULE__.handle_ecto_query/4,
      nil
    )

    safe_attach(
      "ecto-query-error",
      [:ecto, :repo, :query, :exception],
      &__MODULE__.handle_ecto_error/4,
      nil
    )
  end

  defp attach_nats_handlers do
    safe_attach(
      "nats-publish-success",
      [:nats, :pub],
      &__MODULE__.handle_nats_publish/4,
      nil
    )

    safe_attach(
      "nats-publish-error",
      [:nats, :pub, :exception],
      &__MODULE__.handle_nats_error/4,
      nil
    )
  end

  defp attach_retry_handlers do
    safe_attach(
      "retry-attempt",
      [:bot_army_library_runtime, :nats, :retry, :attempt],
      &__MODULE__.handle_retry_attempt/4,
      nil
    )
  end

  defp attach_error_handlers do
    safe_attach(
      "ecto-query-exception-sentry",
      [:ecto, :repo, :query, :exception],
      &__MODULE__.handle_sentry_error/4,
      nil
    )

    safe_attach(
      "nats-pub-exception-sentry",
      [:nats, :pub, :exception],
      &__MODULE__.handle_sentry_error/4,
      nil
    )
  end

  def handle_ecto_query(_event, measurements, metadata, _config) do
    query_time_ms = div(measurements.total_time, 1000)

    if query_time_ms > 1000 do
      Logger.warning("[Ecto] Slow query detected",
        query_time_ms: query_time_ms,
        repo: metadata[:repo],
        source: metadata[:source]
      )
    end
  end

  def handle_ecto_error(_event, measurements, metadata, _config) do
    query_time_ms = div(measurements.total_time, 1000)

    Logger.error("[Ecto] Query failed",
      query_time_ms: query_time_ms,
      repo: metadata[:repo],
      source: metadata[:source],
      error: inspect(metadata[:error])
    )
  end

  def handle_nats_publish(_event, measurements, metadata, _config) do
    publish_time_ms = div(measurements[:duration] || measurements[:total_time] || 0, 1000)

    Logger.debug("[NATS] Message published",
      subject: metadata[:subject],
      publish_time_ms: publish_time_ms
    )
  end

  def handle_nats_error(_event, measurements, metadata, _config) do
    publish_time_ms = div(measurements[:duration] || measurements[:total_time] || 0, 1000)

    Logger.error("[NATS] Publish failed",
      subject: metadata[:subject],
      publish_time_ms: publish_time_ms,
      error: inspect(metadata[:error])
    )
  end

  def handle_retry_attempt(_event, measurements, metadata, _config) do
    payload = %{
      "schema_version" => "1.0",
      "event_type" => "runtime.retry.attempt",
      "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "subject" => metadata[:subject],
      "attempt_number" => measurements.attempt_number,
      "outcome" => Atom.to_string(metadata[:outcome]),
      "reason" => inspect(metadata[:reason]),
      "circuit_breaker_key" => metadata[:circuit_breaker_key]
    }

    try do
      BotArmyLibraryRuntime.NATS.Publisher.publish("events.runtime.retry.attempt", payload)
    rescue
      _ -> :ok
    end
  end

  @doc false
  def handle_sentry_error(_event, _measurements, metadata, _config) do
    if sentry_configured?() do
      try do
        Sentry.capture_exception(metadata[:error],
          extra: %{
            source: metadata[:source],
            repo: metadata[:repo],
            subject: metadata[:subject]
          }
        )
      rescue
        _ -> :ok
      end
    end
  end

  defp sentry_configured? do
    dsn = Application.get_env(:sentry, :dsn)
    is_binary(dsn) and dsn != "" and dsn != nil
  end
end
