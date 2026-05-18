# Troubleshooting

## NATS Connection Issues

### Bot fails to start: "Unable to connect to NATS"

**Symptoms:**
- Application start fails with connection error
- Logs show: `[error] failed to connect to NATS: connection refused`

**Causes:**
- NATS server not running
- Wrong NATS server address in `NATS_SERVERS`
- Network connectivity issue

**Solutions:**

1. **Check NATS is running:**
   ```bash
   nats server check
   # or
   ps aux | grep nats-server
   ```

2. **Verify NATS_SERVERS environment variable:**
   ```bash
   echo $NATS_SERVERS
   # Should be: nats://localhost:4222 or your server address
   ```

3. **Test connectivity:**
   ```bash
   nats request --server nats://localhost:4222 system.health.response '{}' --timeout 3s
   ```

4. **Check network:**
   ```bash
   ping nats.example.com
   nc -zv nats.example.com 4222
   ```

### Frequent reconnections ("KeepAlive timeout")

**Symptoms:**
- Logs show repeated: `[warn] NATS connection lost, reconnecting...`
- Bot loses NATS connectivity every few seconds
- High latency on NATS operations

**Causes:**
- Network instability
- NATS server overload
- Too many bots on one NATS cluster

**Solutions:**

1. **Check NATS server health:**
   ```bash
   nats server stats
   nats server subscribers
   ```

2. **Monitor network latency:**
   ```bash
   ping -c 10 nats.example.com
   ```

3. **Increase reconnect backoff in config:**
   ```elixir
   config :gnat,
     initial_reconnect_delay_ms: 500,
     max_reconnect_delay_ms: 60000
   ```

## Subscription Issues

### Messages not being received

**Symptoms:**
- Subscribed to a subject but no messages arrive
- `handle_info({:msg, msg}, state)` callback never called

**Causes:**
- Subscription created after messages published (NATS doesn't replay history)
- Wrong subject name
- Message publisher is on different NATS cluster

**Solutions:**

1. **Verify subscription is created:**
   ```elixir
   {:ok, sub} = Gnat.sub(conn, self(), "my.subject")
   IO.inspect(sub)  # Should print subscription info
   ```

2. **Check subject name matches:**
   ```bash
   # List all subjects on NATS
   nats sub ">"
   # Then test publisher
   nats pub "my.subject" "test message"
   ```

3. **Verify message is being published:**
   ```bash
   nats sub "my.subject" --all
   # In another terminal
   nats pub "my.subject" "test message"
   ```

## Request/Reply Timeouts

### Gnat.request always times out

**Symptoms:**
- All requests return `{:error, :timeout}`
- No response from service
- Logs show no incoming requests on responder side

**Causes:**
- Responder not subscribed to subject
- Responder crashed or not running
- Subject name mismatch between requester and responder
- Network connectivity issue

**Solutions:**

1. **Verify responder is running:**
   ```bash
   ps aux | grep my_bot
   ```

2. **Check responder is subscribed:**
   ```bash
   nats sub "my.service.request" --all
   ```

3. **Test request from CLI:**
   ```bash
   nats request "my.service.request" "{\"test\": true}" --timeout 5s
   ```

4. **Increase timeout if service is slow:**
   ```elixir
   Gnat.request(conn, subject, payload, receive_timeout: 10000)  # 10 seconds
   ```

## Performance Issues

### High CPU usage or memory leaks

**Symptoms:**
- CPU usage grows over time
- Memory usage increases without bound
- Bot becomes unresponsive

**Causes:**
- Unbounded subscriptions accumulating messages
- Leaking GenServer state
- Publishing too frequently

**Solutions:**

1. **Monitor bot health:**
   ```bash
   nats server report
   ```

2. **Check for leaking subscriptions:**
   - Ensure `handle_info` processes all `:msg` events
   - Unsubscribe when done with a subject

3. **Rate-limit publishing:**
   ```elixir
   # Instead of publishing every millisecond, batch or throttle
   Process.send_after(self(), :publish_batch, 100)
   ```

## Telemetry Issues

### Telemetry events not firing

**Symptoms:**
- Telemetry handlers not being called
- No trace/metric data being collected

**Causes:**
- Telemetry handlers not attached
- Telemetry disabled in config

**Solutions:**

1. **Verify telemetry is enabled:**
   ```elixir
   # config/config.exs
   config :bot_army_runtime, telemetry_enabled: true
   ```

2. **Attach a handler manually:**
   ```elixir
   :telemetry.attach("debug-handler", [:nats, :publish, :stop], 
     fn event, measurements, metadata, _config ->
       IO.inspect({event, measurements, metadata})
     end, nil)
   ```
