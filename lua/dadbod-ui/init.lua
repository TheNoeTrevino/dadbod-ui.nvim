---@mod dadbod-ui  Lua port of vim-dadbod-ui
---
--- A Neovim-native UI on top of vim-dadbod (the query engine). This is the
--- public entry point; `setup()` will grow as subsystems are ported. The
--- dadbod engine boundary lives entirely in `dadbod-ui.bridge`.

local M = {}

local config = require('dadbod-ui.config')
local state = require('dadbod-ui.state')

--- The vim-dadbod boundary (see `lua/dadbod-ui/bridge.lua`).
M.bridge = require('dadbod-ui.bridge')

---@type table  resolved configuration (defaults < legacy globals < setup opts)
M.config = config.resolve()

---@type DadbodUI.Instance|nil  built lazily on first use, reset by setup()
M._instance = nil

--- The central instance, populated from discovery on first access.
---@return DadbodUI.Instance
local function instance()
  if M._instance == nil then
    M._instance = state.new(M.config):populate()
  end
  return M._instance
end

--- Configure the plugin: resolve options, install the dadbod scheme aliases, and
--- reset the instance so the new config takes effect on next use.
---@param opts table|nil
function M.setup(opts)
  M.config = config.resolve(opts)
  M.bridge.ensure_adapters()
  M._instance = nil
  return M
end

--- All discovered connections with their connection state.
---@return DadbodUI.ConnectionInfo[]
function M.connections_list()
  return instance():connections_list()
end

return M
