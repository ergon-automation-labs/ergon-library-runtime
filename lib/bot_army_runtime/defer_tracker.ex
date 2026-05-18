defmodule BotArmyRuntime.DeferTracker do
  @moduledoc """
  ETS-based defer streak tracker for fitness, chores, and any check-in task.

  Tracks how many times a user defers a given task type per week.
  Fast read path via ETS — no GenServer call for `get_defer_count/2`.
  Auto-prunes entries older than 4 weeks on startup and periodically.
  """

  use GenServer

  require Logger

  @table :bot_army_defer_tracker
  @prune_interval_ms :timer.minutes(5)
  @weeks_to_keep 4

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record a defer for the given user and task type.

  Returns the updated defer count for the current week.
  """
  @spec record_defer(String.t(), String.t()) :: non_neg_integer()
  def record_defer(user_id, task_type)
      when is_binary(user_id) and is_binary(task_type) do
    key = make_key(user_id, task_type)
    now = DateTime.utc_now()

    new_count =
      case :ets.lookup(@table, key) do
        [{^key, %{count: count, last_deferred_at: _last}}] ->
          count + 1

        [] ->
          1
      end

    :ets.insert(@table, {key, %{count: new_count, last_deferred_at: now}})
    new_count
  end

  @doc """
  Get the current week's defer count for a user and task type.
  """
  @spec get_defer_count(String.t(), String.t()) :: non_neg_integer()
  def get_defer_count(user_id, task_type)
      when is_binary(user_id) and is_binary(task_type) do
    key = make_key(user_id, task_type)

    case :ets.lookup(@table, key) do
      [{^key, %{count: count}}] -> count
      [] -> 0
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    prune_expired()
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
    now = DateTime.utc_now()
    days_ago = @weeks_to_keep * 7
    cutoff_date = Date.add(now |> DateTime.to_date(), -days_ago)
    {:ok, cutoff} = DateTime.new(cutoff_date, Time.new!(0, 0, 0))

    cutoff = cutoff |> DateTime.shift_zone!("Etc/UTC")

    deleted =
      :ets.select_delete(@table, [
        {{:_, %{last_deferred_at: :"$1", count: :_}}, [{:<, :"$1", {:const, cutoff}}], [true]}
      ])

    if deleted > 0 do
      Logger.debug("[DeferTracker] Pruned #{deleted} expired defer entries")
    end
  end

  defp make_key(user_id, task_type) do
    week = current_week_bucket()
    {user_id, task_type, week}
  end

  defp current_week_bucket do
    today = Date.utc_today()
    # Monday-based week start
    day_of_week = Date.day_of_week(today)
    Date.add(today, -(day_of_week - 1))
  end
end
