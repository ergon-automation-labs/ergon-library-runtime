defmodule BotArmyRuntime.Telemetry do
  @moduledoc """
  Sets up telemetry handlers for observability across Bot Army services.

  Handles:
  - Ecto query metrics
  - NATS publishing metrics
  - Application-level logging
  - Error tracking

  ## Configuration

  Automatically started by `BotArmyRuntime.Application` supervision tree.

  Configure loggers in `config.exs`:

      config :logger,
        backends: [{LoggerJSON.Backends.GoogleCloudLogging, {}}],
        level: :info

  ## Metrics Collected

  - `ecto.query.total_time` - Ecto query execution time
  - `nats.publish.total_time` - NATS message publishing time
  - Errors and exceptions
  """

  use GenServer

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Attach handlers for Ecto
    attach_ecto_handlers()

    # Attach handlers for NATS
    attach_nats_handlers()

    Logger.info("[Telemetry] Initialized")

    {:ok, %{}}
  end

  defp attach_ecto_handlers do
    :telemetry.attach(
      "ecto-query-logging",
      [:ecto, :repo, :query],
      &handle_ecto_query/4,
      nil
    )

    :telemetry.attach(
      "ecto-query-error",
      [:ecto, :repo, :query, :exception],
      &handle_ecto_error/4,
      nil
    )
  end

  defp attach_nats_handlers do
    :telemetry.attach(
      "nats-publish-success",
      [:nats, :pub],
      &handle_nats_publish/4,
      nil
    )

    :telemetry.attach(
      "nats-publish-error",
      [:nats, :pub, :exception],
      &handle_nats_error/4,
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
    publish_time_ms = div(measurements.total_time || 0, 1000)

    Logger.debug("[NATS] Message published",
      subject: metadata[:subject],
      publish_time_ms: publish_time_ms
    )
  end

  def handle_nats_error(_event, measurements, metadata, _config) do
    publish_time_ms = div(measurements.total_time || 0, 1000)

    Logger.error("[NATS] Publish failed",
      subject: metadata[:subject],
      publish_time_ms: publish_time_ms,
      error: inspect(metadata[:error])
    )
  end
end
