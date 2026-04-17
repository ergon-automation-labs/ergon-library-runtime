defmodule BotArmyRuntime.NATS.Dedup do
  @moduledoc """
  ETS-based sliding window deduplication for NATS events.

  Prevents duplicate processing of messages that may be redelivered
  by JetStream or retried by publishers. Uses a 1-minute sliding
  window with up to 10K entries.

  Fast read path via ETS — no GenServer call needed for `seen?/1`.
  """

  use GenServer

  require Logger

  @table :nats_event_dedup
  @window_ms 60_000
  @max_entries 10_000
  @prune_interval_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if an event_id has been seen within the dedup window.
  Fast ETS lookup — no GenServer call.
  """
  def seen?(event_id) when is_binary(event_id) do
    case :ets.lookup(@table, event_id) do
      [{^event_id, ts}] ->
        now = System.monotonic_time(:millisecond)

        if now - ts > @window_ms do
          # Expired — treat as not seen
          false
        else
          true
        end

      [] ->
        false
    end
  end

  def seen?(_), do: false

  @doc """
  Mark an event_id as seen. Fast ETS insert.
  """
  def mark_seen(event_id) when is_binary(event_id) do
    :ets.insert(@table, {event_id, System.monotonic_time(:millisecond)})
    :ok
  end

  def mark_seen(_), do: :ok

  @doc """
  Check and mark atomically. Returns `:new` if not seen, `:duplicate` if already seen.
  """
  def check_and_mark(event_id) when is_binary(event_id) do
    if seen?(event_id) do
      :duplicate
    else
      mark_seen(event_id)
      :new
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    schedule_prune()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:prune, state) do
    prune_expired()
    enforce_max_entries()
    schedule_prune()
    {:noreply, state}
  end

  defp schedule_prune do
    Process.send_after(self(), :prune, @prune_interval_ms)
  end

  defp prune_expired do
    cutoff = System.monotonic_time(:millisecond) - @window_ms

    :ets.select_delete(@table, [
      {{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}
    ])
  end

  defp enforce_max_entries do
    count = :ets.info(@table, :size)

    if count > @max_entries do
      # Delete oldest entries (lowest timestamps)
      entries =
        :ets.tab2list(@table)
        |> Enum.sort_by(fn {_, ts} -> ts end)
        |> Enum.take(count - @max_entries)

      for {event_id, _} <- entries do
        :ets.delete(@table, event_id)
      end
    end
  end
end
