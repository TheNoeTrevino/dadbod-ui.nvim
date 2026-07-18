.PHONY: help test test-integration test-integration-record fmt fmt-check install-hooks

# Bare `make` shows the help rather than silently running the suite.
.DEFAULT_GOAL := help

## Show this help: every target and what it does.
help:
	@echo 'Usage: make <target>'
	@echo
	@awk 'BEGIN { FS = ":" } \
		/^## / { docs[n++] = substr($$0, 4); next } \
		/^[a-zA-Z][a-zA-Z0-9_-]*:/ { \
			if (n) { \
				printf "  \033[36m%-24s\033[0m %s\n", $$1, docs[0]; \
				for (i = 1; i < n; i++) printf "  %-24s %s\n", "", docs[i]; \
				n = 0 \
			} \
			next \
		} \
		{ n = 0 }' $(MAKEFILE_LIST)

## Run the spec suite (lazy.minit + mini.test, one Neovim process).
test:
	./scripts/test

## Run the end-to-end suite against real databases. Needs ONLY docker: the
## servers AND the runner (nvim + every client CLI) are containers. CI runs
## this same path. DBUI_IT_KEEP=1 keeps servers up; DBUI_IT_EXTRA=1 adds more adapters.
test-integration:
	./integration/run.sh check

## (Re)record the golden files from the live databases. Review the diff
## before committing -- a golden change is a deliberate output change.
test-integration-record:
	./integration/run.sh record

## Format all Lua in place with stylua (uses ./stylua.toml).
fmt:
	stylua lua/ plugin/ tests/ integration/

## Check formatting without writing; non-zero exit on any diff (CI-friendly).
fmt-check:
	stylua --check lua/ plugin/ tests/ integration/

## Install the stylua pre-commit hook into .git/hooks.
install-hooks:
	./scripts/install-hooks.sh
