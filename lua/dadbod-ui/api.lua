---@toc_entry API
---@tag dadbod-ui-api
---@text
--- # Scripting API ~
---
--- `require('dadbod-ui.api')` is the stable, user-facing surface for scripting
--- dadbod-ui from Lua. It is a thin FACADE: every function delegates into an
--- internal module (`state`, `bridge`, `introspect`, `connections`, `export`)
--- and holds no logic of its own -- the same single-responsibility rule the rest
--- of the port follows. Lifecycle (`setup`) stays on `require('dadbod-ui')`; this
--- module is for driving connections, introspection, queries and exports.
---
--- Connections are addressed by NAME -- the display name from
--- `require('dadbod-ui.api').list()` (its `key_name` also resolves, to
--- disambiguate a name reused across groups).
---
--- The data-returning verbs (`connect`, `query`, `schemas`, `tables`,
--- `introspect`) are asynchronous and take a `cb(result, err)` callback,
--- mirroring the engine bridge they sit on; `err` is a string on failure and
--- `result` is nil. `query_sync` is the blocking dual for scripts. Query results
--- are the raw, adapter-formatted output lines (`string[]`) -- exactly what the
--- drawer and introspection consume; structured rows are intentionally out of
--- scope for this cut.
---
--- >lua
---   local api = require('dadbod-ui.api')
---   api.query('dev', 'select count(*) from users', function(rows, err)
---     if err then return vim.notify(err, vim.log.levels.ERROR) end
---     vim.print(rows)
---   end)
--- <

---@alias DadbodUI.ApiResultCallback fun(result: string[]|nil, err: string|nil)
---@alias DadbodUI.ApiOkCallback fun(ok: boolean, err: string|nil)

---@class DadbodUI.ApiConnInfo
---@field name string  the display name (not unique across groups)
---@field group string  the group name ('' when ungrouped)
---@field key_name string  the unique key ({group}_{name}_{source}); pass to any api verb
---@field url string  the connection url
---@field conn string  the live resolved connection ('' when not connected)
---@field scheme string  the adapter scheme
---@field tables string[]  known table names (populated after introspection)
---@field schemas string[]  known schema names (populated after introspection)
---@field connected boolean  whether a live connection is held

---@class DadbodUI.ApiIntrospection
---@field schemas string[]  schema names ({} for flat adapters like sqlite)
---@field tables string[]  flat list of table names
---@field routines DadbodUI.RoutineItem[]  stored procedures / functions

---@class DadbodUI.ApiAddSpec
---@field url string  the connection url
---@field name string  the display name
---@field group? string  optional group

---@class DadbodUI.ApiExportSpec
---@field name string  connection name
---@field sql string  the query to run and export
---@field format string  export format (e.g. 'csv', 'json')
---@field path string  destination file path
---@field prefer_native? boolean  use the adapter's native exporter when available (default true)

---@class DadbodUI.ApiModule
---@field open fun(mods?: string)
---@field toggle fun()
---@field close fun()
---@field list fun(): DadbodUI.ConnectionInfo[]
---@field info fun(name: string): DadbodUI.ApiConnInfo|nil
---@field is_connected fun(name: string): boolean
---@field add fun(spec: DadbodUI.ApiAddSpec): boolean, string|nil
---@field connect fun(name: string, cb?: DadbodUI.ApiOkCallback)
---@field schemas fun(name: string, cb: fun(schemas: string[]|nil, err: string|nil))
---@field tables fun(name: string, cb: fun(tables: string[]|nil, err: string|nil))
---@field introspect fun(name: string, cb: fun(data: DadbodUI.ApiIntrospection|nil, err: string|nil))
---@field add_connection fun()
---@field switch_buffer fun(name?: string): boolean, string|nil
---@field find_buffer fun()
---@field rename_buffer fun()
---@field execute_query fun()
---@field execute_selection fun()
---@field cancel_query fun()
---@field last_query_info fun()
---@field query fun(name: string, sql: string, cb: DadbodUI.ApiResultCallback)
---@field query_sync fun(name: string, sql: string): string[]|nil, string|nil
---@field execute fun(name: string, sql: string): boolean, string|nil
---@field export fun(spec: DadbodUI.ApiExportSpec): boolean, string|nil
---@field export_result fun(page_choice?: 'full'|'current')
---@field statusline fun(opts?: DadbodUI.StatuslineOpts): string

local state = require('dadbod-ui.state')
local bridge = require('dadbod-ui.bridge')

---@private
---@type DadbodUI.ApiModule
---@diagnostic disable-next-line: missing-fields
local M = {}

-- Helpers --------------------------------------------------------------------

--- Resolve a connection `name` to its entry. Accepts three forms, in order of
--- precedence:
---   * the full `key_name` (`{group}_{name}_{source}` when grouped, else
---     `{name}_{source}`) -- always unambiguous;
---   * `"{group}/{name}"` -- to pick a specific grouped connection when the bare
---     name is reused across groups;
---   * the bare display `name` -- resolves the first match, so prefer one of the
---     forms above when a name collides across groups.
---@private
---@param name string
---@return DadbodUI.ConnectionEntry|nil
local function resolve(name)
  local instance = state.get()
  local list = instance.dbs_list
  -- Each form is tried as its OWN pass so precedence holds across the whole list:
  -- an exact key_name anywhere beats a bare-name match earlier in the list.
  -- Exact key_name: never ambiguous, so it wins.
  local record = vim.iter(list):find(function(r)
    return r.key_name == name
  end)
  -- `group/name`: the friendly disambiguator for a name reused across groups.
  local group, conn = name:match('^(.+)/(.+)$')
  if record == nil and group ~= nil then
    record = vim.iter(list):find(function(r)
      return r.group == group and r.name == conn
    end)
  end
  -- Bare display name (first match; reached when `name` has no '/' or its
  -- group/name form matched nothing but the literal name still exists).
  if record == nil then
    record = vim.iter(list):find(function(r)
      return r.name == name
    end)
  end
  return record and instance.dbs[record.key_name] or nil
end

--- A fresh introspection controller bound to the current session config, with a
--- no-op render (the drawer is not involved in the scripting path).
---@private
---@return DadbodUI.Introspect
local function controller()
  return require('dadbod-ui.introspect').new({
    config = state.config(),
    connector = bridge.connect,
    render = function() end,
  })
end

--- Turn a completed process result into raw output lines or an error string.
--- `nil` means the spawn never started (missing client binary); a non-zero exit
--- surfaces stderr (falling back to stdout, then the exit code).
---@private
---@param result DadbodUI.SystemCompleted|nil
---@return string[]|nil lines
---@return string|nil err
local function parse_result(result)
  if result == nil then
    return nil, 'query process failed to start (is the client binary installed?)'
  end
  if result.code ~= 0 then
    local err = vim.trim(result.stderr or '')
    if err == '' then
      err = vim.trim(result.stdout or '')
    end
    if err == '' then
      err = 'query failed (exit ' .. tostring(result.code) .. ')'
    end
    return nil, err
  end
  local lines = vim.split(result.stdout or '', '\n')
  for i, line in ipairs(lines) do
    lines[i] = (line:gsub('\r$', ''))
  end
  if #lines > 0 and lines[#lines] == '' then
    lines[#lines] = nil
  end
  return lines
end

--- Ensure `entry` holds a live connection, invoking `cb(ok, err)` when ready.
--- No-op-fast when already connected. Non-blocking (dadbod's auth probe runs
--- through `vim.system`).
---@private
---@param entry DadbodUI.ConnectionEntry
---@param cb DadbodUI.ApiOkCallback
local function ensure_connected(entry, cb)
  if state.is_connected(entry) then
    return cb(true)
  end
  controller():connect_async(entry, function()
    if state.is_connected(entry) then
      cb(true)
    else
      cb(false, entry.conn_error ~= nil and entry.conn_error ~= '' and entry.conn_error or 'connection failed')
    end
  end)
end

-- Drawer ---------------------------------------------------------------------

--- Open the drawer (accepts command modifiers, e.g. `:tab`).
---@param mods? string
function M.open(mods)
  require('dadbod-ui').open(mods)
end

--- Toggle the drawer open/closed.
function M.toggle()
  require('dadbod-ui').toggle()
end

--- Close the drawer.
function M.close()
  require('dadbod-ui').close()
end

-- Connections ----------------------------------------------------------------

--- All discovered connections with their connection state.
---@return DadbodUI.ConnectionInfo[]
function M.list()
  return state.get():connections_list()
end

--- Connection info for `name`, or nil when unknown. The data dual of the
--- drawer's details view: url, live handle, known tables/schemas, scheme and a
--- connected flag. Tables/schemas are only populated once the connection has
--- been introspected (drawer-expanded or via `introspect`).
---@param name string
---@return DadbodUI.ApiConnInfo|nil
function M.info(name)
  local entry = resolve(name)
  if entry == nil then
    return nil
  end
  return {
    name = entry.name,
    group = entry.group,
    key_name = entry.key_name,
    url = entry.url,
    conn = entry.conn or '',
    scheme = entry.scheme,
    tables = entry.tables.list,
    schemas = entry.schemas.list,
    connected = state.is_connected(entry),
  }
end

--- Whether `name` currently holds a live connection. False for an unknown name.
---@param name string
---@return boolean
function M.is_connected(name)
  local entry = resolve(name)
  return entry ~= nil and state.is_connected(entry)
end

--- Add a connection to the `connections.json` store programmatically (the
--- non-interactive dual of `:DBUIAddConnection`). Rediscovers connections on
--- success so the new one is immediately resolvable. Returns `false, err` when
--- no store path is configured (needs `save_location`) or the name/url is
--- invalid or a duplicate.
---@param spec DadbodUI.ApiAddSpec
---@return boolean ok
---@return string|nil err
function M.add(spec)
  local instance = state.get()
  local path = instance.connections_path
  if path == nil then
    return false, 'no connections.json path is configured (set save_location)'
  end
  local connections = require('dadbod-ui.connections')
  local list = connections.read_file(path)
  local new_list, err = connections.add_connection(list, spec.name, spec.url, spec.group)
  if new_list == nil then
    return false, err
  end
  connections.write_file(path, new_list)
  instance:repopulate()
  return true
end

--- Connect `name` (no-op when already connected). Non-blocking; `cb(ok, err)`
--- fires on the main loop once the outcome is known.
---@param name string
---@param cb? DadbodUI.ApiOkCallback
function M.connect(name, cb)
  cb = cb or function() end
  local entry = resolve(name)
  if entry == nil then
    return cb(false, 'no connection named ' .. tostring(name))
  end
  ensure_connected(entry, cb)
end

--- Add a connection interactively (prompts for url + name) -- the Lua equivalent
--- of `:DBUIAddConnection`. Use `add` to add one programmatically instead.
function M.add_connection()
  require('dadbod-ui').add_connection()
end

-- Introspection --------------------------------------------------------------

--- Connect (if needed) and introspect `name`, returning its schemas, tables and
--- routines. Non-blocking; `cb(data, err)` fires once the metadata has landed.
---@param name string
---@param cb fun(data: DadbodUI.ApiIntrospection|nil, err: string|nil)
function M.introspect(name, cb)
  local entry = resolve(name)
  if entry == nil then
    return cb(nil, 'no connection named ' .. tostring(name))
  end
  local ctrl = controller()
  local function connected(ok, err)
    if not ok then
      return cb(nil, err)
    end
    -- `populate` re-renders (our no-op) once the fan-out lands; a once-guard
    -- turns that first render into the one-shot completion. Flat adapters may
    -- render again later when routines land -- the guard keeps the callback
    -- single-fire, so those trail the returned snapshot.
    local fired = false
    ctrl.render = function()
      if fired then
        return
      end
      fired = true
      -- Flatten grouped routines (schema adapters) or take the flat list --
      -- keyed on `schema_support`, exactly as `apply_routines` populates them
      -- (`.flat` is always an initialized table, so it can't discriminate).
      local routines = {}
      if entry.schema_support then
        for _, schema in ipairs(entry.routines.list) do
          vim.list_extend(routines, entry.routines.items[schema].list)
        end
      else
        routines = entry.routines.flat
      end
      cb({
        schemas = entry.schemas.list,
        tables = entry.tables.list,
        routines = routines,
      })
    end
    ctrl:populate(entry)
  end
  if state.is_connected(entry) then
    connected(true)
  else
    ctrl:connect_async(entry, function()
      connected(state.is_connected(entry), entry.conn_error)
    end)
  end
end

--- Connect (if needed), introspect `name` and return just its schema names.
---@param name string
---@param cb fun(schemas: string[]|nil, err: string|nil)
function M.schemas(name, cb)
  M.introspect(name, function(data, err)
    if data == nil then
      return cb(nil, err)
    end
    cb(data.schemas)
  end)
end

--- Connect (if needed), introspect `name` and return just its table names.
---@param name string
---@param cb fun(tables: string[]|nil, err: string|nil)
function M.tables(name, cb)
  M.introspect(name, function(data, err)
    if data == nil then
      return cb(nil, err)
    end
    cb(data.tables)
  end)
end

-- Query ----------------------------------------------------------------------

--- Switch the CURRENT query buffer to connection `name` without prompting -- the
--- scriptable dual of `:DBUISwitchBuffer`. The current buffer must already be a
--- dadbod-ui query buffer; its text, table/schema and bind-param context ride
--- across to the new connection. With no `name`, falls back to the interactive
--- picker (and returns true, as the pick is async). Returns `false, err` when the
--- name is unknown, the current buffer is not a query buffer, or there is no
--- other connection to switch to.
---@param name? string
---@return boolean ok
---@return string|nil err
function M.switch_buffer(name)
  local ok, err = require('dadbod-ui').switch_buffer(name)
  if name == nil then
    return true
  end
  return ok == true, err
end

--- Find/adopt the query buffer for the current db context -- the Lua equivalent
--- of `:DBUIFindBuffer`. Operates on the current buffer.
function M.find_buffer()
  require('dadbod-ui').find_buffer()
end

--- Rename the current query buffer's on-disk file -- the Lua equivalent of
--- `:DBUIRenameBuffer`. Operates on the current buffer.
function M.rename_buffer()
  require('dadbod-ui').rename_buffer()
end

--- Execute the whole current query buffer through dadbod, opening the `.dbout`
--- result window -- the Lua equivalent of the `execute` mapping in normal mode.
function M.execute_query()
  require('dadbod-ui').execute_query()
end

--- Execute the current visual selection through dadbod -- the Lua equivalent of
--- the `execute` mapping in visual mode.
function M.execute_selection()
  require('dadbod-ui').execute_selection()
end

--- Cancel the running async query for the current query buffer -- the Lua
--- equivalent of `:DBUICancelQuery`.
function M.cancel_query()
  require('dadbod-ui').cancel_query()
end

--- Echo the last executed query and its runtime -- the Lua equivalent of
--- `:DBUILastQueryInfo`.
function M.last_query_info()
  require('dadbod-ui').print_last_query_info()
end

--- Run `sql` against `name` and return the raw, adapter-formatted output lines.
--- Connects first if needed. Non-blocking: the query runs through the adapter's
--- own client (`vim.system`), so Neovim stays responsive and no result window is
--- opened -- use `execute` for the drawer's `.dbout` view instead.
---@param name string
---@param sql string
---@param cb DadbodUI.ApiResultCallback
function M.query(name, sql, cb)
  local entry = resolve(name)
  if entry == nil then
    return cb(nil, 'no connection named ' .. tostring(name))
  end
  ensure_connected(entry, function(ok, err)
    if not ok then
      return cb(nil, err)
    end
    bridge.run_many({ bridge.query_command(entry.conn, sql) }, function(results)
      cb(parse_result(results[1]))
    end)
  end)
end

--- Blocking dual of `query` for scripts and tests: connects (blocking) and runs
--- `sql`, returning the raw output lines. Blocks Neovim for the round-trip --
--- prefer `query` in interactive contexts.
---@param name string
---@param sql string
---@return string[]|nil lines
---@return string|nil err
function M.query_sync(name, sql)
  local entry = resolve(name)
  if entry == nil then
    return nil, 'no connection named ' .. tostring(name)
  end
  if not state.is_connected(entry) then
    controller():connect(entry)
    if not state.is_connected(entry) then
      return nil, entry.conn_error ~= nil and entry.conn_error ~= '' and entry.conn_error or 'connection failed'
    end
  end
  local results = bridge.run_many_sync({ bridge.query_command(entry.conn, sql) })
  return parse_result(results[1])
end

--- Execute `sql` against `name` through dadbod's `:DB`, opening the `.dbout`
--- result window -- the UI dual of `query`. Connects first if needed (blocking,
--- since `:DB` needs a live handle on the same tick). Returns `false, err` when
--- the name is unknown or the connection fails.
---@param name string
---@param sql string
---@return boolean ok
---@return string|nil err
function M.execute(name, sql)
  local entry = resolve(name)
  if entry == nil then
    return false, 'no connection named ' .. tostring(name)
  end
  if not state.is_connected(entry) then
    controller():connect(entry)
    if not state.is_connected(entry) then
      return false, entry.conn_error ~= nil and entry.conn_error ~= '' and entry.conn_error or 'connection failed'
    end
  end
  bridge.execute(entry.conn, sql)
  return true
end

-- Export ---------------------------------------------------------------------

--- Run `spec.sql` against `spec.name` and export the result to `spec.path` in
--- `spec.format`, with no drawer or result buffer involved (the headless dual of
--- `:DBUIExportResult`). Connects first if needed (blocking). The export itself
--- is asynchronous and reports success/failure through the plugin's
--- notifications, as the interactive path does. Returns `false, err` for the
--- synchronous pre-flight failures (unknown name, connect failure).
---@param spec DadbodUI.ApiExportSpec
---@return boolean ok
---@return string|nil err
function M.export(spec)
  local entry = resolve(spec.name)
  if entry == nil then
    return false, 'no connection named ' .. tostring(spec.name)
  end
  if not state.is_connected(entry) then
    controller():connect(entry)
    if not state.is_connected(entry) then
      return false, entry.conn_error ~= nil and entry.conn_error ~= '' and entry.conn_error or 'connection failed'
    end
  end
  local export = require('dadbod-ui.export')
  local cfg = state.config().export or {}
  export.export({
    url = entry.conn,
    scheme = entry.scheme,
    format = spec.format,
    query = spec.sql,
    path = spec.path,
    source = spec.name,
    prefer_native = spec.prefer_native ~= false,
    format_opts = export.format_opts(cfg, spec.format, entry.scheme),
  })
  return true
end

--- Interactively export the CURRENT `.dbout` result buffer to a file (prompts for
--- format + path) -- the Lua equivalent of `:DBUIExportResult`. `page_choice`
--- 'current' exports only the on-screen page of a paginated result; 'full' (the
--- default) exports the whole query. Use `export` for a headless, prompt-free
--- export driven by a connection name + SQL.
---@param page_choice? 'full'|'current'
function M.export_result(page_choice)
  require('dadbod-ui.export').export_interactive(vim.api.nvim_get_current_buf(), nil, page_choice)
end

-- Statusline -----------------------------------------------------------------

--- Connection/table info for the current query buffer, or the last query's
--- runtime for a `.dbout` buffer -- safe to embed in a `statusline`/`winbar`
--- expression. Never opens the drawer. Mirrors the original `db_ui#statusline()`.
---@param opts? DadbodUI.StatuslineOpts
---@return string
function M.statusline(opts)
  return require('dadbod-ui').statusline(opts)
end

return M
