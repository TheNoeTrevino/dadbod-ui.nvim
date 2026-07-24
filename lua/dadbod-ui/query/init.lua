-- Query buffers: open, set the b:dbui_* contract, execute
--
-- A `Query` is created over the drawer and owns the SQL buffers: opening a
-- `New query` or a table-helper buffer, setting the buffer-local contract
-- (`b:dbui_db_key_name`, `b:db`, `b:dbui_table_name`, `b:dbui_schema_name`),
-- and executing on save through the bridge's async `:DB` path. Bind parameters
-- (M9) are detected on execute, prompted for, persisted in `b:dbui_bind_params`,
-- and substituted before the SQL reaches the engine; the in-buffer loading
-- symbol and result tracking live in `dadbod-ui.dbout`.
--
-- Connecting and refreshing saved queries go through an injected
-- `dadbod-ui.introspect` controller (an acyclic leaf), not back through the
-- drawer. The one drawer back-ref is `drawer:render()` -- the drawer owns the
-- tree, so a buffer change that should refresh it asks the drawer to redraw.
-- (The drawer in turn reaches back into the query controller for `open_buffer`,
-- e.g. when renaming a buffer file.)
--
-- This file is the facade: the class table, construction and the session-wide
-- quit sweep. The buffer lifecycle (`query/buffers.lua`) and the execution flow
-- (`query/execute.lua`) are method mixins merged into `DadbodUI.Query` here,
-- mirroring the drawer/dbout package layout.

local highlights = require('dadbod-ui.highlights')
local introspect = require('dadbod-ui.introspect')
local utils = require('dadbod-ui.utils')

---@class DadbodUI.QueryModule
---@field connection_winbar fun(entry: DadbodUI.ConnectionEntry, color?: string): string
---@field new fun(drawer: DadbodUI.Drawer): DadbodUI.Query
---@field Query DadbodUI.Query  the class table, exported for the static `write_contract`

---@type DadbodUI.QueryModule
---@diagnostic disable-next-line: missing-fields
local M = {}

--- The right-aligned connection winbar for a query buffer: `group/name` (or just
--- `name` when the connection is ungrouped) in a padded, highlighted block pushed
--- to the right edge with `%=`. `%` in the group/name is doubled so a name can't
--- inject statusline items. `color` (the entry's effective hex color, issue #91)
--- swaps the muted default block for a solid block of that color -- the loud
--- "you are on prod" surface; nil keeps today's look exactly. Pure with respect
--- to windows, for unit tests (the color group is defined as a side effect).
---@param entry DadbodUI.ConnectionEntry
---@param color? string
---@return string
function M.connection_winbar(entry, color)
  local text = utils.display_name(entry.name, entry.group)
  local group = color ~= nil and highlights.winbar_color_group(color) or 'DadbodUIWinbarConnection'
  return string.format('%%=%%#%s# %s ', group, (text:gsub('%%', '%%%%')))
end

---@class DadbodUI.Query
---@field drawer DadbodUI.Drawer  back-ref, used only for drawer:render()
---@field instance DadbodUI.Instance
---@field config DadbodUI.Config
---@field input DadbodUI.UiInput  prompt backend (shared with the drawer; injectable)
---@field select DadbodUI.UiSelect  picker backend for the edit flow (injectable)
---@field introspect DadbodUI.Introspect  connect / load-saved-queries backend
---@field last_query string[]  lines of the most recently executed query
---@field last_query_time string  runtime of the last result in seconds ('' until one lands)
local Query = {}
Query.__index = Query

-- Method mixins: the buffer lifecycle (query/buffers.lua) and the execution
-- flow (query/execute.lua). Their `self` is this same class; merging here keeps
-- `require('dadbod-ui.query')` a single Query.
for _, mixin in ipairs({ 'dadbod-ui.query.buffers', 'dadbod-ui.query.execute' }) do
  for name, method in pairs(require(mixin)) do
    Query[name] = method
  end
end

---@private
--- Arm the session-wide quit sweep for `query`.
---
--- `QuitPre` is the hook, not `VimLeavePre`: Vim raises `E37`/the save prompt
--- while DECIDING to quit, which is before `VimLeavePre` runs -- by then the
--- prompt has already been shown. `QuitPre` fires before that check, so clearing
--- `modified` (or writing) there settles the question silently.
---
--- The autocmd is global rather than buffer-local (`setup_buffer`'s per-buffer
--- group) because a buffer-local `QuitPre` only fires when that buffer is
--- current, and the buffers being prompted about are precisely the hidden ones.
---
--- Re-arming is safe and intended: `clear = true` drops the previous autocmd, so
--- the sweep always runs against the newest controller -- a re-`setup()` rebuilds
--- the drawer (and this `Query`) with the new config, and the old one is dropped
--- rather than pinned alive by a stale closure.
---@param query DadbodUI.Query
---@return nil
local function arm_exit_sweep(query)
  local group = vim.api.nvim_create_augroup('dadbod_ui_query_exit', { clear = true })
  vim.api.nvim_create_autocmd('QuitPre', {
    group = group,
    callback = function()
      query:sweep_on_exit()
    end,
  })
end

--- Create a query controller bound to `drawer`. Connecting and saved-query
--- refresh go through a dedicated introspection controller (built from the
--- drawer's config + injectable connect backend) rather than back through the
--- drawer, so this module depends on `dadbod-ui.introspect` (a leaf), not on a
--- drawer↔query cycle.
---@param drawer DadbodUI.Drawer
---@return DadbodUI.Query
function M.new(drawer)
  local self = setmetatable({
    drawer = drawer,
    instance = drawer.instance,
    config = drawer.config,
    input = drawer.input,
    select = vim.ui.select,
    introspect = introspect.new({
      config = drawer.config,
      connector = drawer.connector,
      render = function()
        drawer:render()
      end,
    }),
    last_query = {},
    last_query_time = '',
  }, Query)
  arm_exit_sweep(self)
  return self
end

M.Query = Query
return M
