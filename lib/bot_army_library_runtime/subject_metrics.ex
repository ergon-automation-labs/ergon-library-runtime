defmodule BotArmyLibraryRuntime.SubjectMetrics do
  @moduledoc """
  Tracks subject call metrics across the Bot Army ecosystem.

  Maintains in-memory counters for every NATS subject published or subscribed to,
  providing visibility into system usage patterns and high-frequency operations.

  ## Features

  - Real-time subject call counting
  - Per-subject success/failure tracking
  - Telemetry event emission for Prometheus/observability
  - Query API for SRE dashboards
  - Automatic metrics export via NATS

  ## Usage

      iex> SubjectMetrics.increment("bot.task.created")
      1

      iex> SubjectMetrics.increment("bot.task.created")
      2

      iex> SubjectMetrics.get_stats("bot.task.created")
      %{calls: 2, failures: 0, last_called_at: ~U[2026-09-02 16:32:33Z]}

      iex> SubjectMetrics.all_stats()
      %{
        "bot.task.created" => %{calls: 2, failures: 0, last_called_at: ...},
        "bot.task.updated" => %{calls: 1, failures: 0, last_called_at: ...}
      }
  """

  use GenServer
  require Logger

  @server __MODULE__

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  @doc "Increment call counter for a subject"
  def increment(subject) when is_binary(subject) do
    GenServer.call(@server, {:increment, subject, :success})
  end

  @doc "Record a failed call for a subject"
  def record_failure(subject) when is_binary(subject) do
    GenServer.call(@server, {:increment, subject, :failure})
  end

  @doc "Get statistics for a specific subject"
  def get_stats(subject) when is_binary(subject) do
    GenServer.call(@server, {:get_stats, subject})
  end

  @doc "Get all statistics (summary)"
  def all_stats do
    GenServer.call(@server, :all_stats)
  end

  @doc "Get top N subjects by call count"
  def top_subjects(limit \\ 10) when is_integer(limit) and limit > 0 do
    GenServer.call(@server, {:top_subjects, limit})
  end

  @doc "Reset all metrics (useful for testing)"
  def reset do
    GenServer.call(@server, :reset)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    Logger.info("Starting SubjectMetrics")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:increment, subject, status}, _from, state) do
    # Update or create entry
    entry = Map.get(state, subject, new_entry())
    updated_entry = update_entry(entry, status)
    new_state = Map.put(state, subject, updated_entry)

    # Emit telemetry
    emit_telemetry(subject, updated_entry)

    {:reply, updated_entry.calls, new_state}
  end

  def handle_call({:get_stats, subject}, _from, state) do
    stats = Map.get(state, subject, %{calls: 0, failures: 0})
    {:reply, stats, state}
  end

  def handle_call(:all_stats, _from, state) do
    # Summarize stats for all subjects
    summary =
      Enum.reduce(state, %{}, fn {subject, entry}, acc ->
        Map.put(acc, subject, %{
          calls: entry.calls,
          failures: entry.failures,
          last_called_at: entry.last_called_at
        })
      end)

    {:reply, summary, state}
  end

  def handle_call({:top_subjects, limit}, _from, state) do
    top =
      state
      |> Enum.sort_by(fn {_subject, entry} -> entry.calls end, :desc)
      |> Enum.take(limit)
      |> Enum.map(fn {subject, entry} ->
        {subject, %{calls: entry.calls, failures: entry.failures}}
      end)

    {:reply, top, state}
  end

  def handle_call(:reset, _from, _state) do
    Logger.info("SubjectMetrics reset")
    {:reply, :ok, %{}}
  end

  # Private helpers

  defp new_entry do
    %{
      calls: 0,
      failures: 0,
      last_called_at: nil
    }
  end

  defp update_entry(entry, :success) do
    %{
      entry
      | calls: entry.calls + 1,
        last_called_at: DateTime.utc_now()
    }
  end

  defp update_entry(entry, :failure) do
    %{
      entry
      | calls: entry.calls + 1,
        failures: entry.failures + 1,
        last_called_at: DateTime.utc_now()
    }
  end

  defp emit_telemetry(subject, entry) do
    # Emit counter metric for call
    :telemetry.execute(
      [:nats, :subject, :call],
      %{value: 1, total_calls: entry.calls, failures: entry.failures},
      %{subject: subject}
    )

    # Emit warning if high failure rate
    if entry.calls > 0 and entry.failures / entry.calls > 0.5 do
      Logger.warning("High failure rate for subject",
        subject: subject,
        failure_rate: entry.failures / entry.calls
      )
    end
  end

  @doc false
  def periodic_summary do
    case all_stats() do
      stats when is_map(stats) ->
        total_calls = Enum.reduce(stats, 0, fn {_, entry}, acc -> acc + entry.calls end)

        log_summary(stats, total_calls)

      _ ->
        :error
    end
  end

  defp log_summary(stats, total_calls) do
    top_10 =
      stats
      |> Enum.sort_by(fn {_subject, entry} -> entry.calls end, :desc)
      |> Enum.take(10)
      |> Enum.map(fn {subject, entry} -> "#{subject}: #{entry.calls}" end)
      |> Enum.join(", ")

    Logger.info("Subject metrics summary",
      total_subjects: map_size(stats),
      total_calls: total_calls,
      top_10_subjects: top_10
    )
  end
end
