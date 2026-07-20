---@toc_entry API
---@tag dadbod-ui-api
---@text
--- # Scripting API ~
---
--- `require('dadbod-ui.api')` is the stable, user-facing surface for scripting
--- dadbod-ui from Lua. It is a thin FACADE: every function delegates into an
--- internal module (`state`, `bridge`, `introspect`, `connections`, `export`)
--- and holds no logic of its own -- the same single-responsibility rule the rest
--- of the plugin follows. Lifecycle (`setup`) stays on `require('dadbod-ui')`; this
--- module is for driving connections, introspection, queries and exports.
---
--- The surface groups into: drawer control (`open`/`toggle`/`close`/`reveal`/
--- `refresh`), connection management (`list`/`info`/`pick`/`add`/`remove`/
--- `rename`/`duplicate`/`set_group`/`move`/`connect`/`disconnect`), introspection
--- (`introspect`), queries (`query`/`query_sync`/`execute`/`execute_pick`/
--- `explain`/`explain_pick`/`open_query`), export (`export`), a runtime event bus
--- (`on`/`off`) for observing the connect/execute/cancel lifecycle, and two
--- buffer-scoped namespaces (`buf`/`dbout`).
---
--- WHERE TO CALL EACH -- the namespace IS the scope, `vim.lsp.buf`-style:
---   * `api.*` -- callable from anywhere; addresses a connection by NAME (or takes
---     explicit args). The scripting/programmatic surface.
---   * `api.buf.*` -- acts on the CURRENT dadbod-ui query buffer (its connection,
---     text, visual selection and bind-param context). Call from a query buffer;
---     these are the Lua duals of that buffer's mappings/commands
---     (see `dadbod-ui.api.buf`).
---   * `api.dbout.*` -- acts on the CURRENT `.dbout` result buffer.
--- The `api.*` verbs are what you script; the `buf`/`dbout` verbs are what you
--- bind to keys or run interactively inside the plugin's own buffers.
--- (`statusline` is the one context-aware exception: safe anywhere, it reports
--- on whichever dadbod-ui buffer is focused.)
---
--- Connections are addressed by NAME -- the display name from
--- `require('dadbod-ui.api').list()` (its `key_name` also resolves, to
--- disambiguate a name reused across groups).
---
--- The data-returning verbs (`connect`, `query`, `explain`, `introspect`)
--- are asynchronous and take a `cb(result, err)` callback,
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
---@field reveal fun(name: string): boolean, string|nil
---@field refresh fun(name: string): boolean, string|nil
---@field list fun(): DadbodUI.ConnectionInfo[]
---@field info fun(name: string): DadbodUI.ApiConnInfo|nil
---@field pick fun(opts?: table)
---@field execute_pick fun(sql: string, opts?: table)
---@field explain_pick fun(sql: string, opts?: DadbodUI.ExplainOpts, picker_opts?: table)
---@field add fun(spec: DadbodUI.ApiAddSpec): boolean, string|nil
---@field remove fun(name: string): boolean, string|nil
---@field rename fun(name: string, new_name: string, new_url?: string): boolean, string|nil
---@field duplicate fun(name: string, new_name: string, group?: string): boolean, string|nil
---@field set_group fun(name: string, group: string): boolean, string|nil
---@field move fun(name: string, direction: 'up'|'down'): boolean, string|nil
---@field connect fun(name: string, cb?: DadbodUI.ApiOkCallback)
---@field disconnect fun(name: string): boolean, string|nil
---@field introspect fun(name: string, cb: fun(data: DadbodUI.ApiIntrospection|nil, err: string|nil))
---@field add_connection fun()
---@field open_query fun(name: string, edit_action?: string): boolean, string|nil
---@field query fun(name: string, sql: string, cb: DadbodUI.ApiResultCallback)
---@field query_sync fun(name: string, sql: string): string[]|nil, string|nil
---@field execute fun(name: string, sql: string): boolean, string|nil
---@field explain fun(name: string, sql: string, opts?: DadbodUI.ExplainOpts|DadbodUI.ApiResultCallback, cb?: DadbodUI.ApiResultCallback)
---@field explain_sync fun(name: string, sql: string, opts?: DadbodUI.ExplainOpts): string[]|nil, string|nil
---@field explain_execute fun(name: string, sql: string, opts?: DadbodUI.ExplainOpts): boolean, string|nil
---@field explain_tree fun(name: string, sql: string, opts?: DadbodUI.ExplainOpts): boolean, string|nil
---@field export fun(spec: DadbodUI.ApiExportSpec): boolean, string|nil
---@field on fun(event: DadbodUI.EventName, cb: fun(event: DadbodUI.HookEvent)): DadbodUI.EventHandle|nil, string|nil
---@field off fun(handle: DadbodUI.EventHandle): boolean
---@field register_adapter fun(spec: DadbodUI.Adapter): DadbodUI.Adapter
---@field statusline fun(opts?: DadbodUI.StatuslineOpts): string
---@field buf DadbodUI.ApiBufModule  verbs acting on the CURRENT query buffer
---@field dbout DadbodUI.ApiDboutModule  verbs acting on the CURRENT `.dbout` result buffer

local state = require('dadbod-ui.state')
local bridge = require('dadbod-ui.bridge')
local dbui = require('dadbod-ui')
local events = require('dadbod-ui.events')
local connections = require('dadbod-ui.connections')
local introspect = require('dadbod-ui.introspect')
local export = require('dadbod-ui.export')
local explain = require('dadbod-ui.explain')
local explain_run = require('dadbod-ui.explain.run')
local notify = require('dadbod-ui.notifications')
local adapters = require('dadbod-ui.adapters')

---@private
---@type DadbodUI.ApiModule
---@diagnostic disable-next-line: missing-fields
local M = {}

M.buf = require('dadbod-ui.api.buf')
M.dbout = require('dadbod-ui.api.dbout')

-- Helpers --------------------------------------------------------------------

-- Connection-name resolution (key_name / group/name / bare name), shared with
-- the buf namespace -- see dadbod-ui.api.resolve.
local resolve = require('dadbod-ui.api.resolve')

--- Resolve `name` to an entry that lives in `connections.json` -- the only ones a
--- store mutation (remove/rename/duplicate/set_group/move) can touch. Returns
--- `nil, err` for an unknown name or a connection sourced from `vim.g.dbs`/env
--- (which the store does not own, so it cannot rewrite).
---@private
---@param name string
---@return DadbodUI.ConnectionEntry|nil, string|nil
local function mutable_entry(name)
  local entry = resolve(name)
  if entry == nil then
    return nil, 'no connection named ' .. tostring(name)
  end
  if entry.source ~= 'file' then
    return nil,
      string.format(
        "connection '%s' is not stored in connections.json (source: %s); only file-backed connections can be modified",
        name,
        entry.source
      )
  end
  return entry
end

--- Read the connections store, apply `fn(connections, list)` (a pure transform
--- returning `(new_list, err)`), persist the result and re-discover so the change
--- is immediately resolvable. The shared spine of every store mutation; mirrors
--- `add`. Returns `false, err` when no store path is configured or `fn` rejects;
--- a `(nil, nil)` transform result is a successful no-op (e.g. a move clamped at
--- the very top/bottom) -- nothing changed, so nothing is written.
---@private
---@param fn fun(connections: DadbodUI.ConnectionsModule, list: DadbodUI.FileConnection[]): DadbodUI.FileConnection[]|nil, string|nil
---@return boolean ok
---@return string|nil err
local function apply_store(fn)
  local instance = state.get()
  local path = instance.connections_path
  if path == nil then
    return false, 'no connections.json path is configured (set save_location)'
  end
  local new_list, err = fn(connections, connections.read_file(path))
  if err ~= nil then
    return false, err
  end
  if new_list ~= nil then
    connections.write_file(path, new_list)
    instance:repopulate()
  end
  return true
end

--- A fresh introspection controller bound to the current session config, with a
--- no-op render (the drawer is not involved in the scripting path).
---@private
---@return DadbodUI.Introspect
local function controller()
  return introspect.new({
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

--- Wrap `sql` in `name`'s adapter EXPLAIN syntax, resolving the connection for
--- its scheme first. Returns `nil, err` for an unknown connection (same message
--- as every other verb) or an adapter that has no explain support -- an early,
--- user-facing error the explain verbs surface before touching the engine.
---@private
---@param name string
---@param sql string
---@param opts? DadbodUI.ExplainOpts
---@return string|nil explain_sql
---@return string|nil err
local function explain_sql(name, sql, opts)
  local entry = resolve(name)
  if entry == nil then
    return nil, 'no connection named ' .. tostring(name)
  end
  return explain.wrap(entry.scheme, sql, opts)
end

-- Drawer ---------------------------------------------------------------------

--- Open the drawer (accepts command modifiers, e.g. `:tab`).
---@param mods? string
function M.open(mods)
  dbui.open(mods)
end

--- Toggle the drawer open/closed.
function M.toggle()
  dbui.toggle()
end

--- Close the drawer.
function M.close()
  dbui.close()
end

--- Open the drawer, expand `name` (introspecting it lazily, as clicking its node
--- would) and put the cursor on it. Returns `false, err` for an unknown name.
---@param name string
---@return boolean ok
---@return string|nil err
function M.reveal(name)
  local entry = resolve(name)
  if entry == nil then
    return false, 'no connection named ' .. tostring(name)
  end
  dbui.reveal(entry.key_name)
  return true
end

--- Re-introspect `name`: reload its saved queries and re-scan schemas/tables from
--- the live database (connecting first if needed), re-rendering the drawer when
--- open. Refreshes the metadata `info`/`tables`/`schemas` report. Returns
--- `false, err` for an unknown name.
---@param name string
---@return boolean ok
---@return string|nil err
function M.refresh(name)
  local entry = resolve(name)
  if entry == nil then
    return false, 'no connection named ' .. tostring(name)
  end
  dbui.refresh(entry.key_name)
  return true
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
    tables = entry.tables,
    schemas = entry.schemas.list,
    connected = state.is_connected(entry),
  }
end

--- Open the connection picker: an interactive list of every discovered
--- connection where `<CR>` connects the selection. The backend is chosen by
--- `config.picker` -- `'auto'` (the default) tries Snacks.nvim, Telescope.nvim,
--- then fzf-lua, falling back to `vim.ui.select` when none is installed. `opts`
--- is passed straight to the underlying picker implementation, so its shape
--- depends on the configured backend (e.g. a `snacks.picker.Config` for snacks).
---@param opts? table
function M.pick(opts)
  -- inline: require cycle (picker.utils calls back into api)
  require('dadbod-ui.picker').show(opts)
end

--- Open the connection picker and run `sql` against the picked connection
--- through dadbod's `:DB`, opening the `.dbout` result window -- `execute` with
--- the name chosen interactively instead of passed in. Callable from anywhere
--- with any sql, so it pairs naturally with a visual-mode mapping that pipes the
--- selection to a database of your choosing:
---
--- >lua
---   vim.keymap.set('v', '<leader>dr', function()
---     local sql = table.concat(
---       vim.fn.getregion(vim.fn.getpos('v'), vim.fn.getpos('.'), { type = vim.fn.mode() }),
---       '\n'
---     )
---     require('dadbod-ui.api').execute_pick(sql)
---   end, { desc = 'Run selection against a picked connection' })
--- <
---
--- Same backend selection and `opts` passthrough as `pick`.
---@param sql string
---@param opts? table
function M.execute_pick(sql, opts)
  require('dadbod-ui.picker').execute(sql, opts)
end

--- Open the connection picker and run `sql`'s EXPLAIN plan against the picked
--- connection, opening the `.dbout` result window -- `explain_execute` with the
--- name chosen interactively, so the plan is wrapped in whatever adapter the
--- pick lands on (unlike hand-prepending `EXPLAIN`, which only fits one
--- dialect). When `opts.analyze` is NOT specified, first prompts for the
--- EXPLAIN / EXPLAIN ANALYZE variant; pass `{ analyze = true }` or
--- `{ analyze = false }` to skip the prompt (analyze RUNS the query for real
--- timings -- side effects for writes). Pairs with a visual-mode mapping the
--- same way `execute_pick` does:
---
--- >lua
---   vim.keymap.set('v', '<leader>de', function()
---     local sql = table.concat(
---       vim.fn.getregion(vim.fn.getpos('v'), vim.fn.getpos('.'), { type = vim.fn.mode() }),
---       '\n'
---     )
---     require('dadbod-ui.api').explain_pick(sql)
---   end, { desc = 'Explain selection against a picked connection' })
--- <
---
--- `picker_opts` is the same backend passthrough as `pick`.
---@param sql string
---@param opts? DadbodUI.ExplainOpts
---@param picker_opts? table
function M.explain_pick(sql, opts, picker_opts)
  require('dadbod-ui.picker').explain(sql, opts, picker_opts)
end

--- Add a connection to the `connections.json` store programmatically (the
--- non-interactive dual of `add_connection`). Rediscovers connections on
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
  local list = connections.read_file(path)
  local new_list, err = connections.add_connection(list, spec.name, spec.url, spec.group)
  if new_list == nil then
    return false, err
  end
  connections.write_file(path, new_list)
  instance:repopulate()
  return true
end

--- Remove `name` from the `connections.json` store (the dual of `add`). Only the
--- exact connection resolved is removed -- a name reused across groups leaves its
--- siblings intact. Returns `false, err` for an unknown or non-file connection.
---@param name string
---@return boolean ok
---@return string|nil err
function M.remove(name)
  local entry, err = mutable_entry(name)
  if entry == nil then
    return false, err
  end
  return apply_store(function(connections, list)
    return connections.delete_connection(list, entry.name, entry.url, entry.group), nil
  end)
end

--- Rename `name` in the store to `new_name` (keeping its group), optionally also
--- changing its url (`new_url` defaults to the current one). Returns `false, err`
--- when `new_name` collides with another connection in the same group, or the name
--- is unknown / non-file.
---@param name string
---@param new_name string
---@param new_url? string
---@return boolean ok
---@return string|nil err
function M.rename(name, new_name, new_url)
  local entry, err = mutable_entry(name)
  if entry == nil then
    return false, err
  end
  return apply_store(function(connections, list)
    return connections.rename_connection(list, entry.name, entry.url, new_name, new_url or entry.url, entry.group)
  end)
end

--- Copy `name` under `new_name` (same url), into `group` when given, else the
--- source's own group. The clone may keep the source name only if it lands in a
--- different group. Returns `false, err` on a same-group name collision or an
--- unknown / non-file source.
---@param name string
---@param new_name string
---@param group? string
---@return boolean ok
---@return string|nil err
function M.duplicate(name, new_name, group)
  local entry, err = mutable_entry(name)
  if entry == nil then
    return false, err
  end
  return apply_store(function(connections, list)
    return connections.duplicate_connection(list, new_name, entry.url, group ~= nil and group or entry.group)
  end)
end

--- Move `name` into `group` (an empty string ungroups it). Returns `false, err`
--- when another connection of the same name already lives in the target group
--- (which would merge them under one key on the next discover), or the name is
--- unknown / non-file.
---@param name string
---@param group string
---@return boolean ok
---@return string|nil err
function M.set_group(name, group)
  local entry, err = mutable_entry(name)
  if entry == nil then
    return false, err
  end
  return apply_store(function(connections, list)
    return connections.set_group(list, entry.name, entry.url, group or '', entry.group)
  end)
end

--- Reorder `name` one slot `'up'` or `'down'` among its group siblings (the drawer's
--- `<C-Up>`/`<C-Down>`), persisting the new order. Clamps at the ends. Returns
--- `false, err` for a bad direction or an unknown / non-file connection.
---@param name string
---@param direction 'up'|'down'
---@return boolean ok
---@return string|nil err
function M.move(name, direction)
  if direction ~= 'up' and direction ~= 'down' then
    return false, "direction must be 'up' or 'down'"
  end
  local entry, err = mutable_entry(name)
  if entry == nil then
    return false, err
  end
  return apply_store(function(connections, list)
    return connections.move_connection(list, entry.name, entry.url, direction, entry.group)
  end)
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

--- Drop `name`'s live connection so `info` reports disconnected and the next
--- query/connect re-probes (the dual of `connect`). Cached tables/schemas are
--- kept -- this forgets the live handle, not the introspected metadata. Returns
--- `false, err` for an unknown name.
---@param name string
---@return boolean ok
---@return string|nil err
function M.disconnect(name)
  local entry = resolve(name)
  if entry == nil then
    return false, 'no connection named ' .. tostring(name)
  end
  state.disconnect(entry)
  return true
end

--- Add a connection interactively (prompts for url + name). Use `add` to add one
--- programmatically instead.
function M.add_connection()
  dbui.add_connection()
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
          vim.list_extend(routines, entry.routines.items[schema])
        end
      else
        routines = entry.routines.flat
      end
      cb({
        schemas = entry.schemas.list,
        tables = entry.tables,
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

-- Query ----------------------------------------------------------------------

--- Open a fresh scratch query buffer bound to `name` -- the programmatic dual of
--- the drawer's "New query" node. `edit_action` is the open command (`'edit'`
--- default, or a split like `'vertical botright split'`). The buffer carries the
--- full `b:dbui_*` contract, so `buf.execute`/`:w` run against `name` and the
--- winbar/completion light up. Returns `false, err` for an unknown name.
---@param name string
---@param edit_action? string
---@return boolean ok
---@return string|nil err
function M.open_query(name, edit_action)
  local entry = resolve(name)
  if entry == nil then
    return false, 'no connection named ' .. tostring(name)
  end
  dbui.open_query(entry.key_name, edit_action)
  return true
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

-- Explain --------------------------------------------------------------------

--- Run `sql`'s EXPLAIN plan against `name` and return the raw, adapter-formatted
--- output lines -- the explain dual of `query`, wrapping `sql` in the adapter's
--- EXPLAIN syntax and running it headlessly (no result window). Pass
--- `{ analyze = true }` for `EXPLAIN ANALYZE`, which RUNS the query for real
--- timings (side effects for writes) -- adapters without an executing form
--- reject it. `opts` may be omitted, passing the callback in its place.
--- Reports an unknown name or an adapter without explain support through `cb`.
---@param name string
---@param sql string
---@param opts? DadbodUI.ExplainOpts|DadbodUI.ApiResultCallback
---@param cb? DadbodUI.ApiResultCallback
function M.explain(name, sql, opts, cb)
  if type(opts) == 'function' then
    opts, cb = nil, opts
  end
  cb = cb or function() end
  local explained, err = explain_sql(name, sql, opts)
  if explained == nil then
    return cb(nil, err)
  end
  M.query(name, explained, cb)
end

--- Blocking dual of `explain` for scripts and tests: wraps `sql` in `name`'s
--- EXPLAIN syntax and runs it (blocking), returning the raw output lines.
--- Returns `nil, err` for an unknown name or an adapter without explain support.
---@param name string
---@param sql string
---@param opts? DadbodUI.ExplainOpts
---@return string[]|nil lines
---@return string|nil err
function M.explain_sync(name, sql, opts)
  local explained, err = explain_sql(name, sql, opts)
  if explained == nil then
    return nil, err
  end
  return M.query_sync(name, explained)
end

--- Execute `sql`'s EXPLAIN plan against `name` through dadbod's `:DB`, opening
--- the `.dbout` result window -- the UI dual of `explain`. Returns `false, err`
--- for an unknown name, an adapter without explain support, or a connect
--- failure.
---@param name string
---@param sql string
---@param opts? DadbodUI.ExplainOpts
---@return boolean ok
---@return string|nil err
function M.explain_execute(name, sql, opts)
  local explained, err = explain_sql(name, sql, opts)
  if explained == nil then
    return false, err
  end
  return M.execute(name, explained)
end

--- Explain `sql` against `name` as an interactive plan TREE: the adapter's
--- JSON EXPLAIN runs headlessly through its own client and the parsed plan
--- opens in the explain-tree split (costs, est-vs-actual rows, timings, heat
--- on the expensive nodes). Connects first if needed (non-blocking). Returns
--- `false, err` for the synchronous pre-flight failures (unknown name,
--- adapter without a structured plan format); async failures (connect, client,
--- decode) surface as notifications. `{ analyze = true }` runs the executing
--- form, rolled back for DML on adapters that allow it.
---@param name string
---@param sql string
---@param opts? DadbodUI.ExplainOpts
---@return boolean ok
---@return string|nil err
function M.explain_tree(name, sql, opts)
  local entry = resolve(name)
  if entry == nil then
    return false, 'no connection named ' .. tostring(name)
  end
  -- Pre-flight with the REAL opts: an adapter without the structured plan
  -- format -- or without an executing form when analyze is requested -- fails
  -- synchronously here, not as an async notification after connecting.
  local wrapped, wrap_err =
    explain.wrap(entry.scheme, sql, { format = 'json', analyze = opts ~= nil and opts.analyze or nil })
  if wrapped == nil then
    return false, wrap_err
  end
  ensure_connected(entry, function(ok, err)
    if not ok then
      return notify.error(err)
    end
    explain_run.open_tree({
      scheme = entry.scheme,
      conn = entry.conn,
      sql = sql,
      analyze = opts ~= nil and opts.analyze or nil,
    })
  end)
  return true
end

-- Export ---------------------------------------------------------------------

--- Run `spec.sql` against `spec.name` and export the result to `spec.path` in
--- `spec.format`, with no drawer or result buffer involved (the headless dual of
--- `dbout.export`). Connects first if needed (blocking). The export itself
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
  local cfg = state.config().results.export or {}
  export.export({
    url = entry.conn,
    scheme = entry.scheme,
    format = spec.format,
    query = spec.sql,
    path = spec.path,
    source = spec.name,
    prefer_native = spec.prefer_native ~= false,
    format_opts = export.format_opts(cfg, spec.format, entry.quote),
  })
  return true
end

-- Events ---------------------------------------------------------------------

--- Subscribe `cb` to a lifecycle `event`, returning a handle to pass to `off`.
--- Unlike the single-slot `config.hooks`, any number of listeners can observe the
--- same event, and they compose with a configured hook rather than replacing it.
--- Listeners are OBSERVERS: an `on_connect` listener sees the event but cannot
--- rewrite the url (that stays the config hook's job). Each fires isolated under
--- `pcall`. Events: `on_connect`, `on_connect_post`, `on_execute_query`,
--- `on_execute_query_post`, `on_cancel_query`, `on_cancel_query_post` (payloads:
--- `DadbodUI.ConnectEvent` / `DadbodUI.QueryEvent` / `DadbodUI.QueryResultEvent` /
--- `DadbodUI.CancelEvent`). Returns `nil, err` for an unknown event name.
---
--- >lua
---   local h = require('dadbod-ui.api').on('on_execute_query_post', function(ev)
---     vim.print(ev.runtime, ev.exit_status)
---   end)
---   -- later: require('dadbod-ui.api').off(h)
--- <
---@param event DadbodUI.EventName
---@param cb fun(event: DadbodUI.HookEvent)
---@return DadbodUI.EventHandle|nil handle
---@return string|nil err
function M.on(event, cb)
  return events.on(event, cb)
end

--- Remove the listener a `handle` (from `on`) refers to. Returns whether one was
--- actually removed (false for a stale or foreign handle).
---@param handle DadbodUI.EventHandle
---@return boolean
function M.off(handle)
  return events.off(handle)
end

-- Adapters -------------------------------------------------------------------

--- Register a custom database adapter (or override a built-in by reusing its
--- name). One spec drives every capability -- drawer introspection, table
--- helpers, EXPLAIN, pagination, export: >lua
---   require('dadbod-ui.api').register_adapter({
---     name = 'duckdb',
---     table_helpers = { List = 'SELECT * FROM "{table}" LIMIT 200' },
---     explain = { plain = 'EXPLAIN {sql}' },
---     pagination = 'limit_offset',
---   })
--- <
--- Register before connecting (entries capture their adapter metadata when the
--- connection list is built).
---@param spec DadbodUI.Adapter
---@return DadbodUI.Adapter
function M.register_adapter(spec)
  return adapters.register(spec)
end

-- Statusline -----------------------------------------------------------------

--- Context-aware (the one exception to the namespace rule): connection/table
--- info for the current query buffer, or the last query's runtime for a
--- `.dbout` buffer -- safe to embed in a `statusline`/`winbar` expression from
--- anywhere. Never opens the drawer. Provides `db_ui#statusline()` semantics.
---@param opts? DadbodUI.StatuslineOpts
---@return string
function M.statusline(opts)
  return dbui.statusline(opts)
end

return M
