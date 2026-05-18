# Contributing

## Development Setup

1. Clone the repository
2. Install Elixir 1.14+
3. Run `mix deps.get` to fetch dependencies
4. Copy `.env.example` to `.env` (if present) and configure local NATS

## Running Tests

```bash
# Unit tests (fast, no external dependencies)
mix test

# Unit + integration tests (requires NATS on port 4224)
mix test --include integration

# Specific test module
mix test test/bot_army_runtime/nats/connection_test.exs

# Specific test with verbose output
mix test test/bot_army_runtime/nats/connection_test.exs:123 --trace
```

## Test Tagging

Tests use `@moduletag` to categorize by feature:

- `:core` - Core runtime modules
- `:nats` - NATS integration tests
- `:telemetry` - Telemetry event tests
- `:registry` - Registry service tests
- `:integration` - Tests requiring external services (NATS, databases)

Filter tests by tag:
```bash
mix test --only nats
mix test --only integration
```

## Code Quality

Before submitting a PR, ensure code passes quality checks:

```bash
# Lint with Credo (code style, readability)
mix credo --strict

# Type check with Dialyzer
mix dialyzer

# Format with Elixir formatter
mix format
```

These checks run in CI and will block merge if they fail.

## Pull Request Process

1. **Create a feature branch:** `git checkout -b feature/my-feature`
2. **Write tests** for new functionality (test-driven development)
3. **Run test suite:** `mix test --include integration`
4. **Check code quality:** `mix credo --strict && mix dialyzer`
5. **Format code:** `mix format`
6. **Commit with clear message:** `git commit -m "feat(nats): add connection pooling"`
7. **Push and open PR** with description of changes and why

## Code Style

- Follow Elixir conventions and guidelines
- Use meaningful variable names
- Keep functions small and focused (single responsibility)
- Add module documentation (`@moduledoc`) for public modules
- Add function documentation (`@doc`) for public functions
- Use pattern matching and guards where appropriate
- Avoid deep nesting; extract helper functions

## Commit Message Format

Use conventional commits:
- `feat(module): description` - New feature
- `fix(module): description` - Bug fix
- `docs(module): description` - Documentation
- `refactor(module): description` - Code refactoring
- `test(module): description` - Test additions/changes

Example: `feat(nats): add automatic reconnection with backoff`
