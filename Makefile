.PHONY: test-handlers test-stores test-nats test-integration test-full help install compile test lint format check docs clean setup-hooks health-check-all push-and-publish release publish-release

SCRIPTS_DIRECTORY ?= $(abspath $(CURDIR)/../scripts)

MIX ?= /Users/abby/.local/share/mise/shims/mix

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

release:
	@echo "==============================================="
	@echo "Building OTP release"
	@echo "==============================================="
	rm -rf _build/prod/rel/bot_army_library_runtime
	MIX_ENV=prod $(MIX) release

publish-release: release
	@echo "==============================================="
	@echo "Publishing release to GitHub"
	@echo "==============================================="
	@echo ""

	@set -e; \
	VERSION=$$(sed -n 's/^[[:space:]]*version:[[:space:]]*"\([^"]*\)".*/\1/p' mix.exs | head -n 1); \
	if [ -z "$$VERSION" ]; then \
		echo "Failed to resolve version from mix.exs"; \
		exit 1; \
	fi; \
	TARBALL=bot_army_library_runtime-$$VERSION.tar.gz; \
	echo "Version: $$VERSION"; \
	echo "Creating release tarball..."; \
	tar -czf "$$TARBALL" -C _build/prod/rel bot_army_library_runtime/; \
	echo "✓ Tarball created: $$TARBALL"; \
	echo ""; \
	echo "Creating GitHub release v$$VERSION..."; \
	if gh release view "v$$VERSION" >/dev/null 2>&1; then \
		gh release upload "v$$VERSION" "$$TARBALL" --clobber; \
	else \
		gh release create "v$$VERSION" "$$TARBALL" \
			--title "Release v$$VERSION" \
			--notes "Bot Army Runtime Elixir release v$$VERSION." \
			--draft=false; \
	fi; \
	echo "✓ Release published to GitHub"

.DEFAULT_GOAL := help


push-and-publish: git-push
	@$(MAKE) publish-release

# Shared targets (push, credo, pre-push-cleanup, bump-version, git-push).
# Defined once in bot_army_infra so they cannot drift per repo.
BOT_ARMY_COMMON_MK := $(abspath $(CURDIR)/../bot_army_infra/make/common.mk)
ifeq ($(wildcard $(BOT_ARMY_COMMON_MK)),)
$(warning bot_army_infra not found at $(BOT_ARMY_COMMON_MK) - shared targets unavailable)
else
include $(BOT_ARMY_COMMON_MK)
endif
