# Deployment

## Environment Variables

### NATS Configuration
- `NATS_SERVERS` - Comma-separated list of NATS servers (default: `nats://localhost:4222`)
- Example: `nats://nats1.example.com:4222,nats://nats2.example.com:4222`

### OpenTelemetry
- `OTEL_EXPORTER_OTLP_ENDPOINT` - OTLP exporter endpoint (default: `http://localhost:4317`)
- `OTEL_SERVICE_NAME` - Service name for traces (e.g., `bot_army_runtime`)

### Logging
- `LOG_LEVEL` - Log verbosity: `debug`, `info`, `warning`, `error` (default: `info`)

## Health Checks

The runtime publishes a heartbeat via `system.health.{bot_name}` every 30 seconds:

```json
{
  "status": "up",
  "timestamp": "2026-05-15T12:00:00Z",
  "version": "0.14.1"
}
```

Monitoring systems can subscribe to `system.health.>` to track bot liveness.

## Configuration

In your bot's `config/config.exs`:

```elixir
config :bot_army_runtime,
  nats_servers: System.get_env("NATS_SERVERS", "nats://localhost:4222"),
  telemetry_enabled: true,
  health_check_interval_ms: 30_000
```

## Troubleshooting

### NATS Connection Errors

**Symptom:** Bot fails to start with "Unable to connect to NATS"

**Cause:** NATS server unreachable

**Solution:**
1. Verify NATS is running: `nats server check`
2. Check `NATS_SERVERS` env var matches your NATS cluster
3. Ensure network connectivity to NATS endpoints

### Missing Health Heartbeats

**Symptom:** Monitoring dashboard shows bot as "down" but process is running

**Cause:** Health check not publishing (telemetry disabled or blocked)

**Solution:**
1. Verify `telemetry_enabled` is true in config
2. Check NATS connection status
3. Review logs for errors during health publish

### High Latency on Requests

**Symptom:** `Gnat.request` calls timeout frequently

**Cause:** Bot taking too long to respond, or NATS network congestion

**Solution:**
1. Increase request timeout if appropriate
2. Check responder bot health and logs
3. Monitor NATS server latency: `nats server report`
