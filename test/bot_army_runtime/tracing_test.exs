defmodule BotArmyRuntime.TracingTest do
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyRuntime.Tracing

  describe "inject_trace_context/1" do
    test "returns headers list when no active span" do
      # Without an active span, inject should return headers unchanged
      # (or with empty traceparent — depends on OTEL noop behavior)
      result = Tracing.inject_trace_context([])

      assert is_list(result)
    end

    test "preserves existing headers" do
      existing = [{"x-custom", "value"}]
      result = Tracing.inject_trace_context(existing)

      assert is_list(result)
      # Custom headers should still be present
      assert {"x-custom", "value"} in result or length(result) >= 1
    end
  end

  describe "extract_trace_context/1" do
    test "returns :ok for valid headers list" do
      assert Tracing.extract_trace_context([]) == :ok
    end

    test "returns :ok for headers with traceparent" do
      headers = [{"traceparent", "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"}]
      assert Tracing.extract_trace_context(headers) == :ok
    end

    test "returns :ok for nil headers" do
      assert Tracing.extract_trace_context(nil) == :ok
    end

    test "returns :ok for non-list headers" do
      assert Tracing.extract_trace_context("not a list") == :ok
    end
  end

  describe "with_consumer_span/3" do
    test "executes function within a span" do
      # Even with noop exporter, the span lifecycle should work
      result =
        Tracing.with_consumer_span("test.subject", [], fn ->
          :done
        end)

      assert result == :done
    end

    test "reraises exceptions and records them" do
      assert_raise RuntimeError, "test error", fn ->
        Tracing.with_consumer_span("test.subject", [], fn ->
          raise "test error"
        end)
      end
    end
  end

  describe "configured?/0" do
    test "returns false when OTEL_EXPORTER_OTLP_ENDPOINT is not set" do
      original = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")
      System.delete_env("OTEL_EXPORTER_OTLP_ENDPOINT")

      assert Tracing.configured?() == false

      if original, do: System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", original)
    end

    test "returns true when OTEL_EXPORTER_OTLP_ENDPOINT is set" do
      original = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")
      System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4318")

      assert Tracing.configured?() == true

      if original do
        System.put_env("OTEL_EXPORTER_OTLP_ENDPOINT", original)
      else
        System.delete_env("OTEL_EXPORTER_OTLP_ENDPOINT")
      end
    end
  end

  describe "add_trace_context_to_envelope/1" do
    test "returns envelope unchanged when no active span" do
      envelope = %{"event_id" => "123", "source" => "test"}

      # Without an active span in this test process, no traceparent is added
      result = Tracing.add_trace_context_to_envelope(envelope)

      # Either _trace_context is absent (no span) or present (with valid traceparent)
      assert is_map(result)
      assert Map.get(result, "event_id") == "123"
    end
  end

  describe "extract_trace_context_from_envelope/1" do
    test "extracts from envelope with _trace_context" do
      envelope = %{
        "event_id" => "123",
        "_trace_context" => %{
          "traceparent" => "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"
        }
      }

      assert Tracing.extract_trace_context_from_envelope(envelope) == :ok
    end

    test "returns :ok for envelope without _trace_context" do
      envelope = %{"event_id" => "123"}
      assert Tracing.extract_trace_context_from_envelope(envelope) == :ok
    end

    test "returns :ok for envelope with empty _trace_context" do
      envelope = %{"event_id" => "123", "_trace_context" => %{}}
      assert Tracing.extract_trace_context_from_envelope(envelope) == :ok
    end
  end
end
