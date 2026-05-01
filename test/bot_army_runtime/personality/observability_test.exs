defmodule BotArmyRuntime.Personality.ObservabilityTest do
  use ExUnit.Case
  @moduletag :format

  alias BotArmyRuntime.Personality.Observability

  describe "soul_get_complete/5" do
    test "emits telemetry with outcome and version" do
      ref = make_ref()
      handler = {:personality_soul_get, ref}

      :ok =
        :telemetry.attach(
          handler,
          [:bot_army, :personality, :soul, :get],
          fn _event, measurements, metadata, _ ->
            send(self(), {:soul_get, measurements, metadata, ref})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      start = System.monotonic_time()
      Observability.soul_get_complete(start, "gtd_bot", "tenant-uuid", :found, 3)

      assert_receive {:soul_get, measurements, metadata, ^ref}
      assert measurements.count == 1
      assert is_integer(measurements.duration)
      assert metadata.bot_id == "gtd_bot"
      assert metadata.tenant_id == "tenant-uuid"
      assert metadata.outcome == :found
      assert metadata.soul_version == 3
    end
  end

  describe "BotArmy.Pulse.publish/3" do
    test "emits personality pulse telemetry (NATS may fail without broker)" do
      ref = make_ref()
      handler = {:personality_pulse, ref}

      :ok =
        :telemetry.attach(
          handler,
          [:bot_army, :personality, :pulse, :publish],
          fn _event, measurements, metadata, _ ->
            send(self(), {:pulse_pub, measurements, metadata, ref})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      BotArmy.Pulse.publish(:gtd_bot, %{status: :active, current_task: "smoke"})

      assert_receive {:pulse_pub, measurements, metadata, ^ref}
      assert measurements.count == 1
      assert metadata.bot_id == "gtd_bot"
      assert metadata.subject == "bot.army.pulse.gtd_bot"
      assert metadata.outcome in [:ok, :error]
    end
  end
end
