.PHONY: test-handlers test-stores test-nats test-integration test-full help install compile test lint format check docs clean setup-hooks health-check-all push-and-publish

help:
	@echo "Bot Army Runtime development tasks"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  install        Install dependencies (npm + mix + install git hooks)"
	@echo "  setup-hooks    Install git hooks for pre-push validation"
	@echo "  compile        Compile the project"
	@echo "  test           Run all tests"
	@echo "  test-watch     Run tests in watch mode"
	@echo "  lint           Run Credo linter"
	@echo "  format         Format code with Elixir formatter"
	@echo "  format-check   Check code formatting"
	@echo "  dialyze        Run Dialyzer type checker"
	@echo "  check          Run all checks (compile + lint + test)"
	@echo "  docs           Generate documentation"
	@echo "  clean          Clean build artifacts"
	@echo "  db-setup       Create and migrate test database"
	@echo "  db-drop        Drop test database"
	@echo "  health-check   Query all bot health endpoints (NATS dev port 4223)"

install: setup-hooks
	$(MIX) deps.get

setup-hooks:
	@git config core.hooksPath git-hooks
	@echo "✓ Git hooks installed (core.hooksPath = git-hooks)"

compile:
	$(MIX) compile

test:
	$(MIX) test

test-handlers:
	MIX_ENV=test $(MIX) test --only handlers --trace

test-stores:
	MIX_ENV=test $(MIX) test --only stores --trace

test-nats:
	MIX_ENV=test $(MIX) test --only nats --trace

test-integration:
	$(MIX) test --include integration --trace

test-full:
	$(MIX) test --include integration --include nats_live --trace

test-watch:
	$(MIX) test.watch

lint:
	$(MIX) credo --only warning

format:
	$(MIX) format

format-check:
	$(MIX) format --check-formatted

dialyze:
	$(MIX) dialyzer

check: compile lint test

docs:
	$(MIX) docs

clean:
	$(MIX) clean
	rm -rf _build

db-setup:
	$(MIX) ecto.create
	$(MIX) ecto.migrate

db-drop:
	$(MIX) ecto.drop

# Bot names for health checks
BOTS := gtd job_applications llm fitness chore terrain learning advocacy sre claude_bridge calendar notification_router context_broker synapse job_scheduler

# Query all bot health endpoints via NATS dev server
health-check:
	@echo "Bot Army Health Check (NATS dev port 4223)"
	@echo "============================================="
	@for bot in $(BOTS); do \
		status=$$(nats request --server nats://localhost:4223 bot.$$bot.health '{}' --timeout 3s 2>/dev/null); \
		if echo "$$status" | grep -q '"status"'; then \
			health=$$(echo "$$status" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4); \
			version=$$(echo "$$status" | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4); \
			printf "  %-22s  %-10s  %s\n" "$$bot" "$$health" "v$$version"; \
		else \
			printf "  %-22s  %-10s  %s\n" "$$bot" "OFFLINE" "-"; \
		fi; \
	done

.DEFAULT_GOAL := help


push-and-publish:
	@git push && $(MAKE) publish-release
