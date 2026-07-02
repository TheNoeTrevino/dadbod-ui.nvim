---@tag dadbod-ui
---@tag dadbod-ui.nvim
---@toc_entry Introduction
---@text
--- # Introduction ~
---
--- dadbod-ui.nvim is a Neovim-native (Lua) port of vim-dadbod-ui: a database UI
--- drawer over tpope/vim-dadbod. It lists connections, browses schemas and
--- tables, opens query buffers, and renders results -- all inside Neovim.
---
--- Session state lives in `dadbod-ui.state` (the single source of truth) and the
--- vim-dadbod engine boundary lives in `dadbod-ui.bridge`. Sibling modules are
--- required lazily so startup cost stays near zero and the dependency graph
--- stays acyclic.
---
--- # Quick Start ~
---                                                        *dadbod-ui-quickstart*
---
--- Setup is optional -- dadbod-ui works with sensible defaults: >lua
---   require('dadbod-ui').setup()
--- <
--- Open the drawer with the `:DBUI` command, or from Lua: >lua
---   require('dadbod-ui').open()
--- <

---@class DadbodUI.InitModule
---@field bridge DadbodUI.BridgeModule  the vim-dadbod boundary
---@field config DadbodUI.Config  resolved config, exposed for inspection (SSOT is dadbod-ui.state)
---@field setup fun(opts?: table): table
---@field open fun(mods?: string)
---@field toggle fun()
---@field close fun()
---@field add_connection fun()
---@field connections_list fun(): DadbodUI.ConnectionInfo[]
---@field execute_query fun()
---@field execute_selection fun()
---@field cancel_query fun()
---@field get_conn_info fun(key_name: string): table
---@field find_buffer fun()
---@field switch_buffer fun(name?: string): boolean|nil, string|nil
---@field open_query fun(key_name: string, edit_action?: string)
---@field reveal fun(key_name: string)
---@field refresh fun(key_name: string)
---@field rename_buffer fun()
---@field print_last_query_info fun()
---@field statusline fun(opts?: DadbodUI.StatuslineOpts): string
---@field reset fun()

local state = require('dadbod-ui.state')

---@private
---@type DadbodUI.InitModule
---@diagnostic disable-next-line: missing-fields
local M = {}

--- The vim-dadbod boundary (see `lua/dadbod-ui/bridge.lua`).
M.bridge = require('dadbod-ui.bridge')

---@type DadbodUI.Config  resolved config, exposed for inspection (SSOT is dadbod-ui.state)
M.config = state.config()

---@private
local _drawer = nil

---@private
---@return DadbodUI.Drawer
local function drawer()
  if _drawer == nil then
    _drawer = require('dadbod-ui.drawer').new(state.get())
  end
  return _drawer
end

--- Configure the plugin: resolve options and drop the cached instance/drawer so
--- the new config takes effect.
---@param opts? table
---@return table
function M.setup(opts)
  M.config = state.setup(opts)
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

--- Add a connection interactively (prompts for url + name), independent of
--- whether the drawer is open. Backs `:DBUIAddConnection`.
function M.add_connection()
  drawer():connections():add_connection()
end

--- All discovered connections with their connection state.
---@return DadbodUI.ConnectionInfo[]
function M.connections_list()
  return state.get():connections_list()
end

--- Execute the current query buffer through dadbod (the whole buffer).
---@return nil
function M.execute_query()
  drawer():query():execute_query(false)
end

--- Execute the current visual selection through dadbod.
---@return nil
function M.execute_selection()
  drawer():query():execute_query(true)
end

--- Cancel the running async query for the current query buffer. Backs
--- `:DBUICancelQuery` and the `cancel` query mapping; fires the `on_cancel_query`
--- / `on_cancel_query_post` hooks around the cancel.
---@return nil
function M.cancel_query()
  drawer():query():cancel_query()
end

--- Connection info for `key_name`, mirroring the original `db_ui#get_conn_info`.
--- Backs the `db_ui#get_conn_info` autoload shim that third-party integrations
--- (e.g. vim-dadbod-completion) call. Returns the resolved url, the live
--- connection handle (empty when not yet connected), the known tables/schemas,
--- the scheme, and a 0/1 connected flag. `{}` for an unknown key.
---@param key_name string
---@return table
function M.get_conn_info(key_name)
  local entry = state.get().dbs[key_name]
  if entry == nil then
    return {}
  end
  return {
    url = entry.url,
    conn = entry.conn or '',
    tables = entry.tables.list,
    schemas = entry.schemas.list,
    scheme = entry.scheme,
    connected = state.is_connected(entry) and 1 or 0,
  }
end

--- Jump to (or adopt) the query buffer for the current db context. Backs
--- `:DBUIFindBuffer`: a buffer already carrying the `b:dbui_*` contract is
--- revealed in the drawer; a bare buffer resolves/connects a db and adopts it.
---@return nil
function M.find_buffer()
  drawer():find_buffer()
end

--- Switch the current query buffer's connection to another one. Backs
--- `:DBUISwitchBuffer`: prompts for a different db, reassigns the buffer
--- (rewriting `b:db`/`b:dbui_db_key_name`, the winbar and the execute-on-save
--- autocmds) without touching the buffer text. A bare buffer falls back to the
--- `find_buffer` assign path. Pass `name` to switch straight to that connection
--- with no prompt (returns `ok, err`); see `dadbod-ui.api.switch_buffer`.
---@param name? string
---@return boolean|nil ok
---@return string|nil err
function M.switch_buffer(name)
  return drawer():switch_buffer(name)
end

--- Open a fresh scratch query buffer bound to the connection `key_name` -- the
--- programmatic equivalent of the drawer's "New query" node. `edit_action` is the
--- open command (`'edit'` default, or a split like `'vertical botright split'`).
--- Delegates to the query controller's open path with a synthetic `query` item.
---@param key_name string
---@param edit_action? string
---@return nil
function M.open_query(key_name, edit_action)
  -- A minimal `query` node is all the open path reads (type + key_name); the other
  -- Node fields are drawer-render concerns the query controller ignores here.
  ---@diagnostic disable-next-line: missing-fields
  drawer():query():open({ type = 'query', key_name = key_name }, edit_action or 'edit')
end

--- Open the drawer, expand the connection `key_name` (introspecting it), and put
--- the cursor on it. Backs `dadbod-ui.api.reveal`.
---@param key_name string
---@return nil
function M.reveal(key_name)
  drawer():reveal_db(key_name)
end

--- Re-introspect the connection `key_name` (reload saved queries + re-scan
--- schemas/tables), re-rendering the drawer when open. Backs `dadbod-ui.api.refresh`.
---@param key_name string
---@return nil
function M.refresh(key_name)
  drawer():refresh_db(key_name)
end

--- Rename the current query buffer's on-disk file (and move its buffer tracking).
--- Backs `:DBUIRenameBuffer`; delegates to the drawer's rename path for the buffer
--- under the cursor / in focus.
---@return nil
function M.rename_buffer()
  drawer():rename_buffer(vim.api.nvim_buf_get_name(0), vim.b.dbui_db_key_name, false)
end

--- Echo the last executed query and its runtime. Backs `:DBUILastQueryInfo`.
--- Mirrors the original `db_ui#print_last_query_info`.
---@return nil
function M.print_last_query_info()
  local notify = require('dadbod-ui.notifications')
  local info = drawer():query():get_last_query_info()
  if #info.last_query == 0 then
    return notify.info('No queries ran.')
  end
  local content = { 'Last query:' }
  vim.list_extend(content, info.last_query)
  if info.last_query_time ~= '' then
    content[#content + 1] = 'Time: ' .. info.last_query_time .. ' sec.'
  end
  notify.info(content, { echo = true })
end

--- Connection/table info for the current query buffer, or the last query's
--- runtime for a `.dbout` result buffer -- a drop-in for the original
--- `db_ui#statusline()`, safe to embed in a `statusline`/`winbar` expression.
--- Reads the `b:dbui_*` contract; never opens the drawer window. Delegates to
--- `Drawer:statusline` (which holds the query controller for the dbout runtime).
---@param opts? DadbodUI.StatuslineOpts
---@return string
function M.statusline(opts)
  return drawer():statusline(opts)
end

--- Reset session state (drops the cached instance and drawer, clears runtime event
--- listeners). For tests/cleanup.
function M.reset()
  state.reset()
  require('dadbod-ui.events').clear()
  _drawer = nil
end

return M
