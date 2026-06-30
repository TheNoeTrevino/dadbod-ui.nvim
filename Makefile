DEPS    := .deps
PLENARY := $(DEPS)/plenary.nvim
DADBOD  := $(DEPS)/vim-dadbod

.PHONY: test deps clean fmt fmt-check install-hooks

## Run the plenary-busted spec suite (headless).
test: deps
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua', sequential = true }"

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
