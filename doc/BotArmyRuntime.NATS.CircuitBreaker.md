# `BotArmyRuntime.NATS.CircuitBreaker`

Generic circuit breaker for NATS inter-bot request-reply calls.

Tracks call failures per bot/subject and opens the circuit after a threshold
is reached, preventing cascading failures when downstream bots are unavailable
or degraded.

States:
- `:closed` — normal operation, requests pass through
- `:open` — too many failures, requests are rejected immediately
- `:half_open` — timeout expired, allowing a single probe request

Rate-limited responses (timeout, 429) can trigger longer cooldowns.

## Configuration

- `:failure_threshold` — consecutive failures before opening (default: 5)
- `:half_open_timeout_ms` — time before trying a probe (default: 30_000)
- `:rate_limit_cooldown_ms` — cooldown after rate-limit (default: 60_000)

## Usage

    # Check before making a request
    case BotArmyRuntime.NATS.CircuitBreaker.allow?("my_bot:target.subject") do
      :ok ->
        # Proceed with request
        {:ok, reply} = BotArmyRuntime.NATS.Publisher.request(...)
        BotArmyRuntime.NATS.CircuitBreaker.record_success("my_bot:target.subject")
        {:ok, reply}

      {:open, retry_after} ->
        # Circuit is open, fail fast
        {:error, {:circuit_open, retry_after}}
    end

    # On timeout or error, record it
    {:error, :timeout} ->
      BotArmyRuntime.NATS.CircuitBreaker.record_failure("my_bot:target.subject", :timeout)
      {:error, :timeout}

# `allow?`

Check if a request is allowed for a given circuit breaker key.

Returns:
- `:ok` — circuit is closed or half-open (request allowed)
- `{:open, retry_after_ms}` — circuit is open, request should fail fast

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `get_state`

Get the current state of a circuit breaker key.

# `record_failure`

Record a failed request. Opens the circuit if threshold is reached.

Pass `:rate_limited` or `:timeout` as reason for longer cooldown.

# `record_success`

Record a successful request. Closes the circuit if it was half-open.

# `start_link`

---

*Consult [api-reference.md](api-reference.md) for complete listing*
