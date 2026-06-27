---@mod dadbod-ui  Lua port of vim-dadbod-ui
---
--- A Neovim-native UI on top of vim-dadbod (the query engine). This is the
--- public entry point; `setup()` will grow as subsystems are ported. The
--- dadbod engine boundary lives entirely in `dadbod-ui.bridge`.

local M = {}

local config = require('dadbod-ui.config')

--- The vim-dadbod boundary (see `lua/dadbod-ui/bridge.lua`).
M.bridge = require('dadbod-ui.bridge')

---@type table  resolved configuration (defaults < legacy globals < setup opts)
M.config = config.resolve()

--- Configure the plugin: resolve options and install the dadbod scheme aliases.
---@param opts table|nil
function M.setup(opts)
  M.config = config.resolve(opts)
  M.bridge.ensure_adapters()
  return M
end

return M
