defmodule BotArmyLibraryRuntime.NATS.JetStreamTest do
  use ExUnit.Case, async: false
  @moduletag :nats

  alias BotArmyLibraryRuntime.NATS.JetStream

  describe "stream_configs/0" do
    test "returns list of stream configurations" do
      configs = JetStream.stream_configs()

      assert is_list(configs)
      assert length(configs) == 10
    end

    test "each config has required fields" do
      for config <- JetStream.stream_configs() do
        assert Map.has_key?(config, :name)
        assert Map.has_key?(config, :subjects)
        assert Map.has_key?(config, :max_age)
        assert is_binary(config.name)
        assert is_list(config.subjects)
        assert is_integer(config.max_age)
      end
    end

    test "includes expected stream names" do
      names = JetStream.stream_configs() |> Enum.map(& &1.name)

      assert "BOT_GTD" in names
      assert "BOT_LLM" in names
      assert "BOT_JOBS" in names
      assert "BOT_EVENTS" in names
      assert "BOT_CLAUDE" in names
      assert "BOT_FITNESS" in names
      assert "BOT_CHORE" in names
      assert "BOT_SRE" in names
      assert "BOT_DLQ" in names
      assert "BUILD_HISTORY" in names
    end

    test "DLQ stream uses dlq.> subject" do
      dlq = JetStream.stream_configs() |> Enum.find(&(&1.name == "BOT_DLQ"))
      assert dlq.subjects == ["dlq.>"]
    end

    test "streams use correct wildcard patterns" do
      configs = JetStream.stream_configs()

      for config <- configs do
        assert Enum.all?(config.subjects, &String.ends_with?(&1, ".>")),
               "Stream #{config.name} subjects should use > wildcard"
      end
    end
  end

  # Mock-based tests for JetStream API calls
  # These test the idempotent logic without needing a real NATS server

  setup_all do
    Application.ensure_all_started(:meck)
    :ok
  end

  setup do
    :meck.new(Gnat.Jetstream.API.Stream, [:non_strict, :no_link])
    :meck.new(Gnat.Jetstream.API.Consumer, [:non_strict, :no_link])
    :meck.new(Gnat.Jetstream, [:non_strict, :no_link])

    on_exit(fn ->
      :meck.unload(Gnat.Jetstream.API.Stream)
      :meck.unload(Gnat.Jetstream.API.Consumer)
      :meck.unload(Gnat.Jetstream)
    end)

    :ok
  end

  describe "ensure_stream/4 (mocked)" do
    test "returns :ok when stream creation succeeds" do
      conn = :mock_conn

      :meck.expect(Gnat.Jetstream.API.Stream, :create, fn ^conn, _stream ->
        {:ok, %{}}
      end)

      result = JetStream.ensure_stream(conn, "TEST_STREAM", ["test.>"])
      assert result == :ok
    end

    test "returns :ok when stream already exists (err_code 10042)" do
      conn = :mock_conn

      :meck.expect(Gnat.Jetstream.API.Stream, :create, fn ^conn, _stream ->
        {:error, %{"err_code" => 10_042}}
      end)

      result = JetStream.ensure_stream(conn, "TEST_STREAM", ["test.>"])
      assert result == :ok
    end

    test "returns error for other creation failures" do
      conn = :mock_conn

      :meck.expect(Gnat.Jetstream.API.Stream, :create, fn ^conn, _stream ->
        {:error, %{"err_code" => 50_000, "description" => "internal error"}}
      end)

      result = JetStream.ensure_stream(conn, "TEST_STREAM", ["test.>"])
      assert match?({:error, _}, result)
    end

    test "passes correct stream configuration" do
      conn = :mock_conn
      me = self()

      :meck.expect(Gnat.Jetstream.API.Stream, :create, fn ^conn, stream ->
        send(me, {:stream_config, stream})
        {:ok, %{}}
      end)

      JetStream.ensure_stream(conn, "MY_STREAM", ["my.>"],
        max_age: 999,
        storage: :memory
      )

      assert_receive {:stream_config, stream}
      assert stream.name == "MY_STREAM"
      assert stream.subjects == ["my.>"]
      assert stream.max_age == 999
      assert stream.storage == :memory
    end

    test "uses default values when opts not provided" do
      conn = :mock_conn
      me = self()

      :meck.expect(Gnat.Jetstream.API.Stream, :create, fn ^conn, stream ->
        send(me, {:stream_config, stream})
        {:ok, %{}}
      end)

      JetStream.ensure_stream(conn, "DEFAULT_STREAM", ["def.>"])

      assert_receive {:stream_config, stream}
      assert stream.retention == :limits
      assert stream.discard == :old
      assert stream.max_msgs == 50_000
      assert stream.num_replicas == 1
    end
  end

  describe "ensure_consumer/4 (mocked)" do
    test "returns :ok when consumer creation succeeds" do
      conn = :mock_conn

      :meck.expect(Gnat.Jetstream.API.Consumer, :create, fn ^conn, _consumer ->
        {:ok, %{}}
      end)

      result = JetStream.ensure_consumer(conn, "TEST_STREAM", "test-durable")
      assert result == :ok
    end

    test "returns :ok when consumer already exists (err_code 10013)" do
      conn = :mock_conn

      :meck.expect(Gnat.Jetstream.API.Consumer, :create, fn ^conn, _consumer ->
        {:error, %{"err_code" => 10_013}}
      end)

      result = JetStream.ensure_consumer(conn, "TEST_STREAM", "test-durable")
      assert result == :ok
    end

    test "returns error for other creation failures" do
      conn = :mock_conn

      :meck.expect(Gnat.Jetstream.API.Consumer, :create, fn ^conn, _consumer ->
        {:error, %{"err_code" => 404, "description" => "stream not found"}}
      end)

      result = JetStream.ensure_consumer(conn, "TEST_STREAM", "test-durable")
      assert match?({:error, _}, result)
    end

    test "passes correct consumer configuration" do
      conn = :mock_conn
      me = self()

      :meck.expect(Gnat.Jetstream.API.Consumer, :create, fn ^conn, consumer ->
        send(me, {:consumer_config, consumer})
        {:ok, %{}}
      end)

      JetStream.ensure_consumer(conn, "MY_STREAM", "my-consumer",
        deliver_subject: "push.my.bot",
        max_deliver: 5,
        ack_wait: 60_000_000_000
      )

      assert_receive {:consumer_config, consumer}
      assert consumer.stream_name == "MY_STREAM"
      assert consumer.durable_name == "my-consumer"
      assert consumer.deliver_subject == "push.my.bot"
      assert consumer.max_deliver == 5
      assert consumer.ack_wait == 60_000_000_000
    end

    test "uses default values when opts not provided" do
      conn = :mock_conn
      me = self()

      :meck.expect(Gnat.Jetstream.API.Consumer, :create, fn ^conn, consumer ->
        send(me, {:consumer_config, consumer})
        {:ok, %{}}
      end)

      JetStream.ensure_consumer(conn, "MY_STREAM", "my-consumer")

      assert_receive {:consumer_config, consumer}
      assert consumer.deliver_policy == :last
      assert consumer.ack_policy == :explicit
      assert consumer.max_deliver == 3
      assert consumer.ack_wait == 30_000_000_000
    end
  end

  describe "ensure_all_streams/1 (mocked)" do
    test "calls create for each configured stream" do
      conn = :mock_conn
      created = :atomics.new(1, signed: false)

      :meck.expect(Gnat.Jetstream.API.Stream, :create, fn ^conn, _stream ->
        :atomics.add(created, 1, 1)
        {:ok, %{}}
      end)

      JetStream.ensure_all_streams(conn)

      assert :atomics.get(created, 1) == length(JetStream.stream_configs())
    end

    test "continues creating remaining streams when one fails" do
      conn = :mock_conn
      created = :atomics.new(1, signed: false)
      call_count = :atomics.new(1, signed: false)

      :meck.expect(Gnat.Jetstream.API.Stream, :create, fn ^conn, stream ->
        :atomics.add(call_count, 1, 1)

        if stream.name == "BOT_EVENTS" do
          {:error, %{"err_code" => 50_000}}
        else
          :atomics.add(created, 1, 1)
          {:ok, %{}}
        end
      end)

      JetStream.ensure_all_streams(conn)

      # All streams attempted, one failed
      assert :atomics.get(call_count, 1) == length(JetStream.stream_configs())
      assert :atomics.get(created, 1) == length(JetStream.stream_configs()) - 1
    end
  end

  describe "ack/1 and nack/1 (mocked)" do
    test "ack delegates to Gnat.Jetstream.ack" do
      msg = %{reply_to: "ack-subject", sid: 1}

      :meck.expect(Gnat.Jetstream, :ack, fn ^msg -> :ok end)

      assert JetStream.ack(msg) == :ok
    end

    test "nack delegates to Gnat.Jetstream.nack" do
      msg = %{reply_to: "ack-subject", sid: 1}

      :meck.expect(Gnat.Jetstream, :nack, fn ^msg -> :ok end)

      assert JetStream.nack(msg) == :ok
    end
  end
end
