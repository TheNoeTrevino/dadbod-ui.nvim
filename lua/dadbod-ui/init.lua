---@mod dadbod-ui  Lua port of vim-dadbod-ui
---
--- A Neovim-native UI on top of vim-dadbod (the query engine). This is the
--- public entry point; `setup()` will grow as subsystems are ported. The
--- dadbod engine boundary lives entirely in `dadbod-ui.bridge`.

local M = {}

--- The vim-dadbod boundary (see `lua/dadbod-ui/bridge.lua`).
M.bridge = require('dadbod-ui.bridge')

---@type table  resolved configuration (config schema lands in a later milestone)
M.config = {}

--- Configure the plugin. For now this only stores options and makes sure the
--- dadbod scheme aliases are installed; the full config schema (a 1:1 mapping of
--- the vimscript `g:db_ui_*` options) is documented in
--- `docs/specs/02-config-schema.md` and will be wired up as modules are ported.
---@param opts table|nil
function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
  M.bridge.ensure_adapters()
  return M
end

return M
