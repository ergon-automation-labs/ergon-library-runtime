defmodule BotArmyRuntime.Intent.AccumulatedContext do
  @moduledoc """
  Rolling window of recent state/events per bot, used by the heartbeat
  to evaluate whether to publish an intent.

  Each bot maintains a ring buffer of context entries — gossip messages,
  activity timestamps, threshold crossings, and other observations — that
  the ThresholdModel reads when deciding whether to act.

  ## Usage

      alias BotArmyRuntime.Intent.AccumulatedContext

      # Start a context buffer for a bot (typically in the bot's supervision tree)
      {:ok, pid} = AccumulatedContext.start_link(bot_name: "gtd", window_size: 50)

      # Record observations from heartbeat cycles
      AccumulatedContext.record("gtd", %{
        type: :stale_task_count,
        value: 5,
        observed_at: DateTime.utc_now()
      })

      AccumulatedContext.record("gtd", %{
        type: :gossip_received,
        value: %{from: "fitness", subject: "morning_check_in"},
        observed_at: DateTime.utc_now()
      })

      # Read the full context snapshot (for ThresholdModel evaluation)
      snapshot = AccumulatedContext.snapshot("gtd")

      # Query recent entries by type
      stale_entries = AccumulatedContext.recent_by_type("gtd", :stale_task_count, count: 10)

  ## Configuration

      config :bot_army_library_runtime, :accumulated_context,
        default_window_size: 100,   # Max entries per bot
        prune_interval_ms: 30_000   # How often to prune stale entries

  Entries older than `@max_entry_age_ms` (default 5 minutes) are pruned
  automatically.
  """

  use GenServer

  require Logger

  @default_window_size 100
  @max_entry_age_ms 300_000
  @prune_interval_ms 30_000

  # ───────────────────────────────────────────────────────────────────────────
  # Client API
  # ───────────────────────────────────────────────────────────────────────────

  @doc """
  Start a context buffer for a bot.

  Options:
    - `:bot_name` — required, the bot this context belongs to
    - `:window_size` — max entries to keep (default 100)
  """
  def start_link(opts) do
    bot_name = Keyword.fetch!(opts, :bot_name)
    GenServer.start_link(__MODULE__, opts, name: via(bot_name))
  end

  @doc """
  Record an observation in a bot's context buffer.

  If no buffer process exists for the bot, starts one dynamically.
  """
  @spec record(String.t(), map()) :: :ok
  def record(bot_name, entry) when is_binary(bot_name) and is_map(entry) do
    ensure_started(bot_name)
    GenServer.cast(via(bot_name), {:record, normalize_entry(entry)})
  end

  @doc """
  Record multiple observations at once.
  """
  @spec record_batch(String.t(), [map()]) :: :ok
  def record_batch(bot_name, entries) when is_binary(bot_name) and is_list(entries) do
    ensure_started(bot_name)
    normalized = Enum.map(entries, &normalize_entry/1)
    GenServer.cast(via(bot_name), {:record_batch, normalized})
  end

  @doc """
  Get a snapshot of the current context for a bot.

  Returns a map with:
    - `:entries` — all entries in the ring buffer (newest first)
    - `:summary` — computed summary statistics by entry type
    - `:bot_name` — the bot name
    - `:entry_count` — number of entries
    - `:window_size` — max window size
  """
  @spec snapshot(String.t()) :: map()
  def snapshot(bot_name) when is_binary(bot_name) do
    case whereis(bot_name) do
      nil -> empty_snapshot(bot_name)
      pid -> GenServer.call(pid, :snapshot)
    end
  end

  @doc """
  Get recent entries of a specific type.

  Returns up to `count` entries of the given type, newest first.
  """
  @spec recent_by_type(String.t(), atom(), keyword()) :: [map()]
  def recent_by_type(bot_name, type, opts \\ []) do
    count = Keyword.get(opts, :count, 10)

    case whereis(bot_name) do
      nil -> []
      pid -> GenServer.call(pid, {:recent_by_type, type, count})
    end
  end

  @doc """
  Get the count of entries matching a type.
  """
  @spec count_by_type(String.t(), atom()) :: non_neg_integer()
  def count_by_type(bot_name, type) do
    case whereis(bot_name) do
      nil -> 0
      pid -> GenServer.call(pid, {:count_by_type, type})
    end
  end

  @doc """
  Get the most recent entry of a specific type.
  """
  @spec latest(String.t(), atom()) :: map() | nil
  def latest(bot_name, type) do
    case whereis(bot_name) do
      nil -> nil
      pid -> GenServer.call(pid, {:latest, type})
    end
  end

  @doc """
  Clear all entries for a bot's context buffer.
  """
  @spec clear(String.t()) :: :ok
  def clear(bot_name) do
    case whereis(bot_name) do
      nil -> :ok
      pid -> GenServer.call(pid, :clear)
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # GenServer Callbacks
  # ───────────────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    bot_name = Keyword.fetch!(opts, :bot_name)
    window_size = Keyword.get(opts, :window_size, config_window_size())

    state = %{
      bot_name: bot_name,
      window_size: window_size,
      entries: [],
      started_at: DateTime.utc_now()
    }

    schedule_prune()
    {:ok, state}
  end

  @impl true
  def handle_cast({:record, entry}, state) do
    new_entries = [entry | state.entries] |> Enum.take(state.window_size)
    {:noreply, %{state | entries: new_entries}}
  end

  @impl true
  def handle_cast({:record_batch, entries}, state) do
    new_entries = (entries ++ state.entries) |> Enum.take(state.window_size)
    {:noreply, %{state | entries: new_entries}}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    snapshot = %{
      bot_name: state.bot_name,
      entries: state.entries,
      summary: compute_summary(state.entries),
      entry_count: length(state.entries),
      window_size: state.window_size,
      started_at: state.started_at
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_call({:recent_by_type, type, count}, _from, state) do
    entries =
      state.entries
      |> Enum.filter(&(&1.type == type))
      |> Enum.take(count)

    {:reply, entries, state}
  end

  @impl true
  def handle_call({:count_by_type, type}, _from, state) do
    count = Enum.count(state.entries, &(&1.type == type))
    {:reply, count, state}
  end

  @impl true
  def handle_call({:latest, type}, _from, state) do
    entry =
      state.entries
      |> Enum.filter(&(&1.type == type))
      |> List.first()

    {:reply, entry, state}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | entries: []}}
  end

  @impl true
  def handle_info(:prune, state) do
    cutoff = DateTime.add(DateTime.utc_now(), -div(@max_entry_age_ms, 1000), :second)
    pruned = Enum.filter(state.entries, &(DateTime.compare(&1.observed_at, cutoff) in [:gt, :eq]))
    schedule_prune()
    {:noreply, %{state | entries: pruned}}
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Private
  # ───────────────────────────────────────────────────────────────────────────

  @doc false
  def normalize_entry(entry) do
    Map.merge(
      %{
        type: :observation,
        value: nil,
        observed_at: DateTime.utc_now(),
        metadata: %{}
      },
      entry
    )
  end

  @doc false
  def compute_summary(entries) do
    entries
    |> Enum.group_by(& &1.type)
    |> Enum.map(fn {type, type_entries} ->
      values = Enum.map(type_entries, & &1.value)

      summary = %{
        count: length(type_entries),
        latest: List.first(type_entries),
        values: values
      }

      {type, summary}
    end)
    |> Map.new()
  end

  defp schedule_prune do
    Process.send_after(self(), :prune, config_prune_interval())
  end

  defp config_window_size do
    config = Application.get_env(:bot_army_library_runtime, :accumulated_context, [])
    Keyword.get(config, :default_window_size, @default_window_size)
  end

  defp config_prune_interval do
    config = Application.get_env(:bot_army_library_runtime, :accumulated_context, [])
    Keyword.get(config, :prune_interval_ms, @prune_interval_ms)
  end

  defp via(bot_name) do
    {:via, Registry,
     {BotArmyRuntime.AccumulatedContextRegistry, {:accumulated_context, bot_name}}}
  end

  defp whereis(bot_name) do
    case Registry.lookup(
           BotArmyRuntime.AccumulatedContextRegistry,
           {:accumulated_context, bot_name}
         ) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp ensure_started(bot_name) do
    case whereis(bot_name) do
      nil ->
        # Dynamic start — will be under the Application supervisor
        spec = {__MODULE__, bot_name: bot_name}

        case DynamicSupervisor.start_child(BotArmyRuntime.DynamicSupervisor, spec) do
          {:ok, _pid} ->
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[AccumulatedContext] Failed to start for #{bot_name}: #{inspect(reason)}"
            )

            :ok
        end

      _pid ->
        :ok
    end
  end

  defp empty_snapshot(bot_name) do
    %{
      bot_name: bot_name,
      entries: [],
      summary: %{},
      entry_count: 0,
      window_size: config_window_size(),
      started_at: nil
    }
  end
end
