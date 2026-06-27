---@mod dadbod-ui  Lua port of vim-dadbod-ui
---
--- Public entry point / facade. Session state lives in `dadbod-ui.state` (the
--- single source of truth); the dadbod engine boundary lives in
--- `dadbod-ui.bridge`. Sibling modules are required lazily so startup cost stays
--- near zero and the dependency graph stays acyclic.

local state = require('dadbod-ui.state')

local M = {}

--- The vim-dadbod boundary (see `lua/dadbod-ui/bridge.lua`).
M.bridge = require('dadbod-ui.bridge')

---@type DadbodUI.Config  resolved config, exposed for inspection (SSOT is dadbod-ui.state)
M.config = state.config()

local _drawer = nil

---@return DadbodUI.Drawer
local function drawer()
  if _drawer == nil then
    _drawer = require('dadbod-ui.drawer').new(state.get())
  end
  return _drawer
end

--- Configure the plugin: resolve options, install dadbod scheme aliases, and
--- drop the cached instance/drawer so the new config takes effect.
---@param opts? table
---@return table
function M.setup(opts)
  M.config = state.setup(opts)
  M.bridge.ensure_adapters()
  _drawer = nil
  return M
end

--- Open the drawer (accepts command modifiers, e.g. `:tab`).
---@param mods? string
function M.open(mods)
  drawer():open(mods)
end

--- Toggle the drawer open/closed.
function M.toggle()
  drawer():toggle()
end

--- Close the drawer.
function M.close()
  drawer():close()
end

--- All discovered connections with their connection state.
---@return DadbodUI.ConnectionInfo[]
function M.connections_list()
  return state.get():connections_list()
end

--- Reset session state (drops the cached instance and drawer). For tests/cleanup.
function M.reset()
  state.reset()
  _drawer = nil
end

return M
