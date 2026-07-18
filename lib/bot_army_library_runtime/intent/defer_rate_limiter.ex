defmodule BotArmyLibraryRuntime.Intent.DeferRateLimiter do
  @moduledoc """
  ETS-based rate limiter for defer-initiated LLM conversations.

  Prevents the same bot+action from starting an LLM conversation
  on every heartbeat when deferred. Uses a sliding window: tracks
  the last defer timestamp per key and enforces a minimum interval.

  Fast read path via ETS — no GenServer call for `check/1`.
  """

  use GenServer

  require Logger

  @table :defer_rate_limit
  @prune_interval_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if a defer conversation is allowed for the given key.

  Returns `:allowed` or `{:rate_limited, remaining_ms}`.
  Fast ETS lookup — no GenServer call.
  """
  @spec check(String.t()) :: :allowed | {:rate_limited, non_neg_integer()}
  def check(key) when is_binary(key) do
    min_interval = min_interval_ms()

    case :ets.lookup(@table, key) do
      [{^key, ts}] ->
        now = System.monotonic_time(:millisecond)
        elapsed = now - ts

        if elapsed >= min_interval do
          :allowed
        else
          {:rate_limited, min_interval - elapsed}
        end

      [] ->
        :allowed
    end
  end

  @doc """
  Record that a defer conversation was started for the given key.
  """
  @spec mark(String.t()) :: :ok
  def mark(key) when is_binary(key) do
    :ets.insert(@table, {key, System.monotonic_time(:millisecond)})
    :ok
  end

  @doc """
  Combined check-and-mark. Returns `:allowed` and marks, or `{:rate_limited, remaining_ms}`.
  """
  @spec check_and_mark(String.t()) :: :allowed | {:rate_limited, non_neg_integer()}
  def check_and_mark(key) when is_binary(key) do
    case check(key) do
      :allowed ->
        mark(key)
        :allowed

      {:rate_limited, _} = limited ->
        limited
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
    schedule_prune()
    {:noreply, state}
  end

  defp schedule_prune do
    Process.send_after(self(), :prune, @prune_interval_ms)
  end

  defp prune_expired do
    # Prune entries older than 2x the min interval
    cutoff = System.monotonic_time(:millisecond) - min_interval_ms() * 2

    :ets.select_delete(@table, [
      {{:_, :"$1"}, [{:<, :"$1", cutoff}], [true]}
    ])
  end

  defp min_interval_ms do
    Application.get_env(:bot_army_library_runtime, :defer_handler, [])
    |> Keyword.get(:min_interval_ms, 30 * 60 * 1000)
  end
end