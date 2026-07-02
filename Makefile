DEPS    := .deps
PLENARY := $(DEPS)/plenary.nvim
DADBOD  := $(DEPS)/vim-dadbod

.PHONY: test test-integration test-integration-record deps clean fmt fmt-check install-hooks

## Run the spec suite (lazy.minit + mini.test, one Neovim process).
test:
	./scripts/test

## Run the export integration suite against real databases in Docker, comparing
## output to committed goldens. Needs docker + the psql/mysql/sqlite3 clients.
test-integration: deps
	./integration/run.sh check

## (Re)record the export golden files from the live databases. Review the diff
## before committing -- a golden change is a deliberate output change.
test-integration-record: deps
	./integration/run.sh record

## Format all Lua in place with stylua (uses ./stylua.toml).
fmt:
	stylua lua/ plugin/ tests/

## Check formatting without writing; non-zero exit on any diff (CI-friendly).
fmt-check:
	stylua --check lua/ plugin/ tests/

## Install the stylua pre-commit hook into .git/hooks.
install-hooks:
	./scripts/install-hooks.sh

## Clone test dependencies into .deps/ (idempotent).
deps: $(PLENARY) $(DADBOD)

$(PLENARY):
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $(PLENARY)

$(DADBOD):
	git clone --depth 1 https://github.com/tpope/vim-dadbod $(DADBOD)

clean:
	rm -rf $(DEPS)
