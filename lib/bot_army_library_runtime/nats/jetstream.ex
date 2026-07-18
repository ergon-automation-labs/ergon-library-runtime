defmodule BotArmyLibraryRuntime.NATS.JetStream do
  @moduledoc """
  JetStream stream and consumer management for Bot Army services.

  Provides idempotent creation of streams and durable consumers,
  ensuring messages are not lost during consumer disconnects.

  Uses the gnat Jetstream API (Gnat.Jetstream.API.Stream and
  Gnat.Jetstream.API.Consumer for creation, Gnat.Jetstream for ack/nack).

  ## Stream Topology

  | Stream | Subjects | Retention |
  |--------|----------|----------|
  | BOT_GTD | gtd.> | 30 days |
  | BOT_LLM | llm.> | 7 days |
  | BOT_JOBS | job.> | 30 days |
  | BOT_EVENTS | events.> | 30 days |
  | BOT_CLAUDE | bot_army.claude.> | 7 days |
  | BOT_FITNESS | fitness.> | 7 days |
  | BOT_CHORE | chore.> | 7 days |
  | BOT_SRE | sre.> | 7 days |
  | BOT_DLQ | dlq.> | 30 days |
  | BUILD_HISTORY | ops.> | 30 days |
  """

  alias Gnat.Jetstream.API.Stream
  alias Gnat.Jetstream.API.Consumer

  require Logger

  @stream_configs [
    %{name: "BOT_GTD", subjects: ["gtd.>"], max_age: 2_592_000_000_000},
    %{name: "BOT_LLM", subjects: ["llm.>"], max_age: 604_800_000_000},
    %{name: "BOT_JOBS", subjects: ["job.>"], max_age: 2_592_000_000_000},
    %{name: "BOT_EVENTS", subjects: ["events.>"], max_age: 2_592_000_000_000},
    %{name: "BOT_CLAUDE", subjects: ["bot_army.claude.>"], max_age: 604_800_000_000},
    %{name: "BOT_FITNESS", subjects: ["fitness.>"], max_age: 604_800_000_000},
    %{name: "BOT_CHORE", subjects: ["chore.>"], max_age: 604_800_000_000},
    %{name: "BOT_SRE", subjects: ["sre.>"], max_age: 604_800_000_000},
    %{name: "BOT_DLQ", subjects: ["dlq.>"], max_age: 2_592_000_000_000},
    %{name: "BUILD_HISTORY", subjects: ["ops.>"], max_age: 2_592_000_000_000}
  ]

  @doc """
  Ensure all Bot Army streams exist. Idempotent — safe to call on every startup.
  """
  def ensure_all_streams(conn) do
    Enum.each(@stream_configs, fn config ->
      ensure_stream(conn, config.name, config.subjects,
        max_age: config.max_age,
        storage: :file
      )
    end)
  end

  @doc """
  Ensure a JetStream stream exists. Idempotent — no-op if stream already exists.
  """
  def ensure_stream(conn, name, subjects, opts \\ []) do
    stream = %Stream{
      name: name,
      subjects: subjects,
      retention: Keyword.get(opts, :retention, :limits),
      max_age: Keyword.get(opts, :max_age, 2_592_000_000_000),
      storage: Keyword.get(opts, :storage, :file),
      discard: Keyword.get(opts, :discard, :old),
      max_msgs: Keyword.get(opts, :max_msgs, 50_000),
      num_replicas: Keyword.get(opts, :replicas, 1)
    }

    case Stream.create(conn, stream) do
      {:ok, _} ->
        Logger.info("[JetStream] Stream #{name} created")
        :ok

      {:error, %{"err_code" => 10_042}} ->
        :ok

      {:error, reason} ->
        Logger.warning("[JetStream] Failed to create stream #{name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Ensure a durable JetStream consumer exists. Idempotent.

  Options:
  - `:deliver_subject` — push delivery subject (required for push consumers)
  - `:deliver_policy` — `:last` (default), `:all`, `:new`
  - `:max_deliver` — max redelivery attempts (default 3)
  - `:ack_policy` — `:explicit` (default), `:all`, `:none`
  - `:ack_wait` — ack timeout in nanoseconds (default 30s)
  - `:filter_subject` — restrict delivery to a subset of a wildcard stream's
    subjects (e.g. a single `ops.*` event type out of a stream covering `ops.>`)
  """
  def ensure_consumer(conn, stream_name, durable_name, opts \\ []) do
    consumer = %Consumer{
      stream_name: stream_name,
      durable_name: durable_name,
      deliver_subject: Keyword.get(opts, :deliver_subject),
      deliver_policy: Keyword.get(opts, :deliver_policy, :last),
      ack_policy: Keyword.get(opts, :ack_policy, :explicit),
      max_deliver: Keyword.get(opts, :max_deliver, 3),
      ack_wait: Keyword.get(opts, :ack_wait, 30_000_000_000),
      filter_subject: Keyword.get(opts, :filter_subject)
    }

    case Consumer.create(conn, consumer) do
      {:ok, _} ->
        Logger.info("[JetStream] Consumer #{durable_name} on #{stream_name} created")
        :ok

      {:error, %{"err_code" => 10_013}} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[JetStream] Failed to create consumer #{durable_name}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Acknowledge a JetStream message (confirm successful processing).
  """
  def ack(msg) do
    Gnat.Jetstream.ack(msg)
  end

  @doc """
  Negatively acknowledge a JetStream message (trigger redelivery).
  """
  def nack(msg) do
    Gnat.Jetstream.nack(msg)
  end

  @doc """
  Return the stream configurations for external use (e.g., Salt automation).
  """
  def stream_configs, do: @stream_configs
end
