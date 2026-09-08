defmodule BotArmyLibraryRuntime.Reminders do
  @moduledoc """
  Periodic reminder scheduler for Bot Army bots.

  A GenServer that polls a bot's own store on a fixed interval and publishes
  notifications for overdue items through the standard NATS event envelope.
  The "what is overdue" question is bot-specific: each bot supplies a
  `check_fn` that queries its own store and returns `{item_id, days_overdue}`
  tuples. This module owns the shared part — the tick loop, urgency-tier
  resolution, and the event envelope — so bots don't drift on event shape.

  ## Usage

  In your bot's supervisor:

      children = [
        BotArmyLibraryRuntime.Reminders.child_spec(
          bot_name: "chore_bot",
          check_interval_minutes: 60,
          reminders: [
            %{
              thing_type: "task",
              check_fn: &BotArmyChore.Scheduler.check_overdue_tasks/0,
              urgency_tiers: [
                {1, "due"},
                {3, "overdue"},
                {7, "urgent"}
              ]
            }
          ]
        )
      ]

  ## Urgency Tiers

  Tiers are `{days_threshold, urgency_level}` tuples; the highest matching
  threshold wins:

  - 1-2 days overdue: `"due"`
  - 3-6 days overdue: `"overdue"`
  - 7+ days overdue: `"urgent"`
  - nothing matching: `"normal"`

  ## Events

  Published to `events.<bot_name>.<thing_type>.notification` with an
  `item_id`, `thing_type`, `days_overdue`, and `urgency` payload — consumed
  by the notification router on the surface side.

  ## History

  Folded in from the standalone `bot_army_library_reminder_scheduler` repo
  (2026-09-08): two consumers did not justify a fourth top-level library,
  and runtime already hosts the periodic/publish helper category (Pulse,
  FleetStatePublisher).
  """

  use GenServer
  require Logger

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    bot_name = Keyword.fetch!(opts, :bot_name)
    interval_minutes = Keyword.get(opts, :check_interval_minutes, 60)
    reminders = Keyword.fetch!(opts, :reminders)

    Logger.info(
      "[Reminders] Starting for #{bot_name} with #{length(reminders)} reminder types"
    )

    # First check shortly after boot, then recurring on the interval.
    Process.send_after(self(), :check_reminders, 1000)

    {:ok,
     %{
       bot_name: bot_name,
       interval_ms: interval_minutes * 60 * 1000,
       reminders: reminders
     }}
  end

  @impl true
  def handle_info(:check_reminders, state) do
    Logger.debug("[Reminders] Checking reminders for #{state.bot_name}")

    Enum.each(state.reminders, &check_reminder_type(state.bot_name, &1))

    Process.send_after(self(), :check_reminders, state.interval_ms)
    {:noreply, state}
  end

  defp check_reminder_type(bot_name, reminder_config) do
    %{thing_type: thing_type, check_fn: check_fn, urgency_tiers: urgency_tiers} =
      reminder_config

    try do
      items = check_fn.()

      Enum.each(items, fn {item_id, days_overdue} ->
        urgency = determine_urgency(days_overdue, urgency_tiers)
        publish_reminder(bot_name, thing_type, item_id, days_overdue, urgency)
      end)
    rescue
      e ->
        Logger.error("[Reminders] Error checking #{thing_type} reminders: #{inspect(e)}")
    end
  end

  defp determine_urgency(days_overdue, urgency_tiers) do
    urgency_tiers
    |> Enum.reverse()
    |> Enum.find_value(fn {threshold, urgency} ->
      if days_overdue >= threshold, do: urgency
    end)
    |> case do
      nil -> "normal"
      urgency -> urgency
    end
  end

  defp publish_reminder(bot_name, thing_type, item_id, days_overdue, urgency) do
    event = %{
      "event" => "#{bot_name}.#{thing_type}.notification",
      "event_id" => UUID.uuid4(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_#{bot_name}",
      "source_node" => "localhost",
      "triggered_by" => "reminder_scheduler",
      "schema_version" => "1.0",
      "payload" => %{
        "item_id" => item_id,
        "thing_type" => thing_type,
        "days_overdue" => days_overdue,
        "urgency" => urgency
      }
    }

    subject = "events.#{bot_name}.#{thing_type}.notification"

    case BotArmyLibraryRuntime.NATS.Publisher.publish(subject, event) do
      :ok ->
        Logger.debug("[Reminders] Published reminder: #{subject} urgency=#{urgency}")

      {:error, reason} ->
        Logger.error("[Reminders] Failed to publish reminder: #{inspect(reason)}")
    end
  end
end