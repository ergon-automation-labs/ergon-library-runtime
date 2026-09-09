# Runtime coverage report (2026-09-09, excoveralls 0.18)

Tooling: `{:excoveralls, "~> 0.18", only: :test}` + `mix coveralls` /
`mix coveralls.detail` / `mix coveralls.json` (config in `coveralls.json`,
`test/support` skipped). Run `MIX_ENV=test mix coveralls` to regenerate.

**Baseline: 40.4% (2048 missed / 3439 relevant lines), 410 tests green.**

## Priority gaps (by missed lines)

| missed | total | module | note |
|-------:|------:|--------|------|
| 209 | 230 | `nats/conversation/manager.ex` | conversation lifecycle — biggest hole |
| 161 | 351 | `registry.ex` | the RERUN16-19 echo-flip lives here; timing tests cover the sweep guard, not the presence/message paths (54.1%) |
| 75 | 93 | `nats/publisher.ex` | request/3 retry ladder untested |
| 74 | 144 | `gossip_poll_affinity.ex` | 51.4% — affinity rebalancing |
| 71 | 76 | `intent/accumulated_context.ex` | 6.5% |
| 69 | 96 | `heartbeat.ex` | 28.4% — heartbeat persistence/upsert |
| 64 | 71 | `intent/reflection_job.ex` | 9.8% |
| 61 | 77 | `intent/veto_listener.ex` | 20.9% |
| 60 | 137 | `kill_switch.ex` | 56.2% — kill-switch semantics partially tested |
| 60 | 63 | `nats/circuit_breaker.ex` | 4.7% — breaker open/half-open transitions |
| 56 | 56 | `intent/publisher.ex` | **0%** |
| 53 | 53 | `nats/conversation/envelope.ex` | **0%** — the Decoder contract (bare payload rejected / wrapped accepted) belongs here |
| 40 | 40 | `factory_fixer_queue.ex` | **0%** |
| 36 | 36 | `fleet_state_publisher.ex` | **0%** |
| 0 | — | `nats/conversation/reply.ex`, `nats/conv…` 2 more, `outcomes.ex`, `reminders.ex`, `config.ex`, `ecto/circuit_breaker.ex`, `ecto/repo.ex`, `logger_formatter.ex`, `logging.ex` | zero-coverage set (see `mix coveralls`) |

## Reading the shape

- **Highest-risk untested cluster = `nats/`** (connection, publisher, circuit
  breaker, conversation/* ≈ 900 relevant lines at <25%). This is the layer the
  2026-09-08/09 outages moved through (breaker churn, echo-flip).
- **Second = `intent/`** (accumulated_context, reflection_job, veto_listener,
  publisher ≈ 260 missed lines). Mostly decision logic — cheap to unit test,
  no NATS needed.
- **Well-covered already:** jetstream (100%), dedup (86.9%), personality
  core (94-100%), telemetry (77%), tracing (79.4%), theme_renderer (85.7%).

## Suggested L1 order (highest value per test)

1. `nats/conversation/envelope.ex` Decoder contract — pure, tiny, unblocks the
   `nats_publish.sh` lesson as a regression test.
2. `nats/circuit_breaker.ex` — force failures through open→half-open→closed.
3. `nats/publisher.ex` request/3 — retry/timeout ladder with a mock connection.
4. `intent/accumulated_context.ex` + `intent/publisher.ex` — pure logic.
5. `registry.ex` presence-path matrix (upsert/mark_remote/evict branches beyond
   the timing tests in `registry_timing_test.exs`).