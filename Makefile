.PHONY: help install compile test lint format check docs clean setup-hooks

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

install: setup-hooks
	mix deps.get

setup-hooks:
	@git config core.hooksPath git-hooks
	@echo "✓ Git hooks installed (core.hooksPath = git-hooks)"

compile:
	mix compile

test:
	mix test

test-watch:
	mix test.watch

lint:
	mix credo

format:
	mix format

format-check:
	mix format --check-formatted

dialyze:
	mix dialyzer

check: compile lint test

docs:
	mix docs

clean:
	mix clean
	rm -rf _build

db-setup:
	mix ecto.create
	mix ecto.migrate

db-drop:
	mix ecto.drop

.DEFAULT_GOAL := help
