DEPS    := .deps
PLENARY := $(DEPS)/plenary.nvim
DADBOD  := $(DEPS)/vim-dadbod

.PHONY: test deps clean

## Run the plenary-busted spec suite (headless).
test: deps
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua', sequential = true }"

## Clone test dependencies into .deps/ (idempotent).
deps: $(PLENARY) $(DADBOD)

$(PLENARY):
	git clone --depth 1 https://github.com/nvim-lua/plenary.nvim $(PLENARY)

$(DADBOD):
	git clone --depth 1 https://github.com/tpope/vim-dadbod $(DADBOD)

clean:
	rm -rf $(DEPS)
