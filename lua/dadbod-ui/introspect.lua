-- Connect + schema/table introspection for a connection
--
-- Connects a connection (sync, as dadbod does) and introspects its
-- schemas/tables, folding the results into the connection `entry` and
-- re-rendering. It operates purely on the entry plus the adapter metadata in
-- `schemas`, so it never requires `drawer` or `query` -- the dependency graph
-- stays acyclic and `state` remains the sink. The drawer (and the query
-- controller) build one of these, injecting the connect backend and a render
-- callback.
--
-- Introspection is non-blocking: schema-supporting adapters fan their schema-
-- list and table-list queries out concurrently via `bridge.run_many`; the
-- tables-only path uses dadbod's `tables` adapter call. Each path re-renders
-- once its data lands, so a large database never freezes the UI.

---@alias DadbodUI.Connector fun(url: string): string
---@alias DadbodUI.ConnectOnResult fun(ok: boolean, conn: string)
---@alias DadbodUI.AsyncConnector fun(url: string, on_result: DadbodUI.ConnectOnResult)
---@alias DadbodUI.IntrospectOpts { config: DadbodUI.Config, connector: DadbodUI.Connector, async_connector?: DadbodUI.AsyncConnector, render: fun(), repaint?: fun(key_name: string, frame: string) }

---@class DadbodUI.IntrospectModule
---@field new fun(opts: DadbodUI.IntrospectOpts): DadbodUI.Introspect
---@field Introspect DadbodUI.Introspect

---@private
local bridge = require('dadbod-ui.bridge')
---@private
local schemas = require('dadbod-ui.schemas')
---@private
local spinner = require('dadbod-ui.spinner')
---@private
local spinners = require('dadbod-ui.spinners')
---@private
local state = require('dadbod-ui.state')

---@type DadbodUI.IntrospectModule
---@diagnostic disable-next-line: missing-fields
local M = {}

---@class DadbodUI.Introspect
---@field config DadbodUI.Config
---@field connector fun(url: string): string  synchronous connect backend (injectable for specs)
---@field async_connector DadbodUI.AsyncConnector  non-blocking connect backend (injectable for specs)
---@field render fun(): nil  re-render callback (the drawer's render)
---@field repaint fun(key_name: string, frame: string): nil  single-line db-node repaint (the drawer's repaint_db_node); animates the loading spinner without a full render
local Introspect = {}
Introspect.__index = Introspect

--- Build an introspection controller. `connector` is dadbod's connect (injectable
--- so specs run offline); `render` is invoked after async schema/table data lands
--- (connecting and saved-query refresh never render). `repaint` drives the
--- per-frame loading animation on a single db node (defaults to a no-op so a
--- controller built without it -- e.g. the query controller -- never crashes).
---@param opts DadbodUI.IntrospectOpts
---@return DadbodUI.Introspect
function M.new(opts)
  return setmetatable({
    config = opts.config,
    connector = opts.connector,
    async_connector = opts.async_connector or bridge.connect_async,
    render = opts.render,
    repaint = opts.repaint or function() end,
  }, Introspect)
end

--- Fire the `on_connect` hook and return the (possibly rewritten) url to connect
--- with. It may return a rewritten url (e.g. a `$password` placeholder swapped
--- for a real secret); when it does, we connect with THAT, so `entry.conn` -- and
--- hence every downstream execution / introspection reading `b:db`/`entry.conn`
--- -- uses the authed connection. A nil / non-string return (or a throwing hook)
--- leaves the original url.
---@param entry DadbodUI.ConnectionEntry
---@return string
function Introspect:_pre_connect(entry)
  return require('dadbod-ui.hooks').transform(self.config, 'on_connect', {
    url = entry.url,
    name = entry.name,
    key_name = entry.key_name,
    group = entry.group,
  }) or entry.url
end

--- Fold a connect outcome into `entry` and fire `on_connect_post`. Shared by the
--- synchronous and async connect paths so their result handling is identical.
--- No "Connecting..." notification: the drawer's inline loading indicator on the
--- db node communicates progress. Success is silent too -- the connection_ok icon
--- signals it and the elapsed time lands in the details view (`H`) rather than a
--- popup. Only a failure interrupts with a notification.
---@param entry DadbodUI.ConnectionEntry
---@param url string  the url connected with (post-`on_connect`)
---@param ok boolean
---@param conn string  the resolved connection on success, or the error on failure
---@param started integer  vim.uv.hrtime() captured before the connect
---@return nil
function Introspect:_apply_connect(entry, url, ok, conn, started)
  if ok then
    entry.conn = conn
    entry.conn_error = ''
    entry.connect_ms = math.floor((vim.uv.hrtime() - started) / 1e6 + 0.5)
  else
    entry.conn = ''
    entry.conn_error = tostring(conn)
    require('dadbod-ui.notifications').error(string.format('Error connecting to db %s: %s', entry.name, tostring(conn)))
  end
  entry.conn_tried = true

  -- Fire `on_connect_post` after, with the outcome. Isolated like the rest: a
  -- throwing post-hook must not undo a successful connect. (`conn`/`error` are
  -- assigned explicitly rather than via `and/or` so a nil branch isn't swallowed.)
  local post = {
    url = url,
    name = entry.name,
    key_name = entry.key_name,
    group = entry.group,
    success = ok,
  }
  if ok then
    post.conn = conn
  else
    post.error = tostring(conn)
  end
  require('dadbod-ui.hooks').run(self.config, 'on_connect_post', post)
end

--- Connect a connection if not already connected (SYNCHRONOUS -- blocks Neovim).
--- Kept for the query / manual-assign paths that must have a live `b:db` before
--- proceeding on the same tick. Errors are captured on the entry (surfaced as the
--- error icon) and notified. The drawer-expand path uses
--- the non-blocking `connect_async` instead.
---@param entry DadbodUI.ConnectionEntry
---@return DadbodUI.ConnectionEntry
function Introspect:connect(entry)
  if state.is_connected(entry) then
    return entry
  end
  local url = self:_pre_connect(entry)
  local started = vim.uv.hrtime()
  local ok, conn = pcall(self.connector, url)
  self:_apply_connect(entry, url, ok, conn, started)
  return entry
end

--- Connect a connection WITHOUT blocking Neovim, invoking `on_done` (on the main
--- loop) once the outcome has been folded into `entry`. The auth probe runs via
--- `async_connector` (dadbod's probe dispatched through `vim.system`), so the UI
--- stays responsive -- and the drawer's spinner can animate -- during the
--- server round-trip. No-op-safe if already connected.
---@param entry DadbodUI.ConnectionEntry
---@param on_done fun(): nil
---@return nil
function Introspect:connect_async(entry, on_done)
  if state.is_connected(entry) then
    return on_done()
  end
  local url = self:_pre_connect(entry)
  local started = vim.uv.hrtime()
  self.async_connector(url, function(ok, conn)
    self:_apply_connect(entry, url, ok, conn, started)
    on_done()
  end)
end

--- Introspect a connected entry: schema-supporting adapters fan out their
--- schema/table queries, the rest list tables directly.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Introspect:populate(entry)
  if entry.schema_support then
    self:populate_schemas(entry)
  else
    self:populate_tables(entry)
  end
end

--- Connect then introspect a connection on expand, WITHOUT blocking Neovim. We
--- paint the loading indicator first (mark `loading` + render) and START the
--- animated spinner, then run the connect via `connect_async` -- dadbod's auth
--- probe dispatched through `vim.system` -- so the server round-trip no longer
--- freezes the UI (the old code merely `vim.schedule`d the blocking `db#connect`,
--- deferring the freeze by one tick but not removing it). Because the connect is
--- async now, the event loop is free to tick the spinner timer across the WHOLE
--- window -- connect and the `populate_schemas` fan-out both -- rather than
--- showing a frozen static frame during the connect. `populate_schemas` keeps the
--- spinner running (a seamless restart); the failure branch and the sqlite
--- tables path stop it. (sqlite's `tables` call is a brief local block, so its
--- frame may still sit for that moment.)
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Introspect:expand_db(entry)
  self:load_saved_queries(entry)
  entry.loading = true
  self.render()
  spinner.start(entry.key_name, spinners.dots, function(frame)
    self.repaint(entry.key_name, frame)
  end)
  self:connect_async(entry, function()
    if not state.is_connected(entry) then
      entry.loading = false
      spinner.stop(entry.key_name)
      self.render()
      return
    end
    if entry.schema_support then
      self:populate_schemas(entry)
    else
      self:populate_tables(entry)
    end
  end)
end

--- Refresh `entry.saved_queries.list` from the files on disk under its save_path.
--- Lives here so the query controller can refresh saved queries without reaching
--- back through the drawer.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Introspect:load_saved_queries(entry)
  if entry.save_path ~= '' then
    entry.saved_queries.list = vim.fn.glob(entry.save_path .. '/*', true, true)
  end
end

--- Whether `schema_name` matches any `hide_schemas` pattern (Vim regexes).
---@param schema_name string
---@return boolean
function Introspect:_is_schema_ignored(schema_name)
  return vim.iter(self.config.hide_schemas):any(function(pattern)
    return vim.fn.match(schema_name, pattern) > -1
  end)
end

--- Introspect schemas + tables concurrently and render, with the two queries
--- fanned out via `run_many`.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Introspect:populate_schemas(entry)
  if not state.is_connected(entry) then
    entry.loading = false
    spinner.stop(entry.key_name)
    return
  end
  local scheme_info = schemas.get(entry.scheme, self.config)
  local specs = {
    schemas.command_spec(entry.conn, scheme_info, scheme_info.schemes_query),
    schemas.command_spec(entry.conn, scheme_info, scheme_info.schemes_tables_query),
  }
  -- Fold routine introspection into the SAME concurrent fan-out (a third spec)
  -- when the adapter supports it, so procedures/functions load alongside schemas
  -- and tables without a second round-trip. sqlite (no `procedures_query`) simply
  -- never adds the spec -- a clean no-op.
  if entry.routine_support then
    specs[#specs + 1] = schemas.command_spec(entry.conn, scheme_info, scheme_info.procedures_query)
  end
  -- The async `run_many` window is the only time a timer can tick, so this is
  -- where we ANIMATE: each frame repaints just the db node's line (no full
  -- render). Stopped on the render that lands the data below. Set loading here
  -- too so a redraw of an already-expanded db (no preceding expand_db) animates.
  entry.loading = true
  spinner.start(entry.key_name, spinners.dots, function(frame)
    self.repaint(entry.key_name, frame)
  end)
  bridge.run_many(specs, function(results)
    spinner.stop(entry.key_name)
    entry.loading = false
    local schema_list = scheme_info.parse_results(schemas.result_lines(results[1]), 1)
    local table_rows = scheme_info.parse_results(schemas.result_lines(results[2]), 2)
    self:apply_schemas(entry, schema_list, table_rows)
    if entry.routine_support then
      local routine_rows = scheme_info.parse_results(schemas.result_lines(results[3]), 3)
      self:apply_routines(entry, scheme_info, routine_rows)
    end
    self.render()
  end)
end

--- Fold parsed schema names and (schema, table) rows into the entry, honoring
--- `hide_schemas`: tables are grouped per schema and also collected into the
--- flat `entry.tables.list`.
---@param entry DadbodUI.ConnectionEntry
---@param schema_list string[]
---@param table_rows string[][]
---@return nil
function Introspect:apply_schemas(entry, schema_list, table_rows)
  local visible_schemas = vim.tbl_filter(function(schema)
    return not self:_is_schema_ignored(schema)
  end, schema_list)

  local tables_by_schema = {}
  entry.tables.list = {}
  for _, row in ipairs(table_rows) do
    local schema_name, table_name = row[1], row[2]
    if not self:_is_schema_ignored(schema_name) then
      tables_by_schema[schema_name] = tables_by_schema[schema_name] or {}
      table.insert(tables_by_schema[schema_name], table_name)
      table.insert(entry.tables.list, table_name)
    end
  end

  entry.schemas.list = visible_schemas
  -- Rebuilt fresh each introspection: these are pure domain containers, so
  -- there is no view state to preserve (the drawer's expand map is keyed by
  -- stable ids and survives on its own).
  entry.schemas.items = {}
  for _, schema in ipairs(visible_schemas) do
    local schema_tables = tables_by_schema[schema] or {}
    table.sort(schema_tables)
    entry.schemas.items[schema] = { tables = { list = schema_tables } }
  end
end

--- Build a single `DadbodUI.RoutineItem` from a parsed `(schema, name, kind)`
--- row, pre-computing its definition/source query via the adapter's
--- `routine_definition` (so the drawer's open action reuses the table-helper open
--- path verbatim). `kind` is normalized to 'procedure'/'function'; anything else
--- (defensive) falls back to 'function'.
---@param scheme_info DadbodUI.SchemaAdapter
---@param schema string
---@param name string
---@param raw_kind string
---@return DadbodUI.RoutineItem
function Introspect:_make_routine(scheme_info, schema, name, raw_kind)
  local kind = raw_kind == 'procedure' and 'procedure' or 'function'
  local content = scheme_info.routine_definition and scheme_info.routine_definition(schema, name, kind) or ''
  return { name = name, kind = kind, content = content }
end

--- Fold parsed `(schema, name, kind)` routine rows into `entry.routines`. Schema-
--- supporting adapters group routines per schema (mirroring `apply_schemas`,
--- honoring `hide_schemas` and preserving each schema node's expand state); flat
--- adapters collect every routine into `entry.routines.flat`. This lists the
--- database's stored procedures and functions in the drawer.
---@param entry DadbodUI.ConnectionEntry
---@param scheme_info DadbodUI.SchemaAdapter
---@param routine_rows string[][]
---@return nil
function Introspect:apply_routines(entry, scheme_info, routine_rows)
  if entry.schema_support then
    -- Build a fresh items table in one pass: schemas that no longer have routines
    -- simply never enter it (pruning). `order` preserves first-seen schema order
    -- for the drawer.
    local items, order = {}, {}
    for _, row in ipairs(routine_rows) do
      local schema_name, name, kind = row[1], row[2], row[3]
      if not self:_is_schema_ignored(schema_name) then
        if items[schema_name] == nil then
          items[schema_name] = { list = {} }
          order[#order + 1] = schema_name
        end
        table.insert(items[schema_name].list, self:_make_routine(scheme_info, schema_name, name, kind))
      end
    end
    entry.routines.list = order
    entry.routines.items = items
  else
    entry.routines.flat = vim
      .iter(routine_rows)
      :map(function(row)
        return self:_make_routine(scheme_info, row[1], row[2], row[3])
      end)
      :totable()
  end
end

--- Introspect tables for a non-schema adapter (e.g. sqlite) via dadbod's
--- `tables` adapter call and render, including the sqlite whitespace fix and the
--- mysql warning filter. When the adapter also
--- exposes routines (mysql pointed at a single database), those are fetched
--- concurrently via `run_many` and folded in on land.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Introspect:populate_tables(entry)
  entry.tables.list = {}
  if not state.is_connected(entry) then
    entry.loading = false
    spinner.stop(entry.key_name)
    return
  end
  -- The adapter `tables` call is BLOCKING, so no animation is possible here: the
  -- static loading frame painted on expand is the indicator until the rows land.
  local raw = bridge.adapter_call(entry.conn, 'tables', { entry.conn }, {})
  entry.tables.list = schemas.normalize_table_list(entry.scheme, raw)
  local scheme_info = schemas.get(entry.scheme, self.config)
  if entry.routine_support then
    -- Routines aren't part of dadbod's `tables` call, so fetch them separately and
    -- non-blockingly; the tree renders now and fills in the Procedures node on land.
    -- Prefer the database-scoped query (`tables_procedures_query`) here: this path
    -- has no schema browsing, so without the scope the global `procedures_query`
    -- would list routines from every schema on the server into this one db's node.
    local query = scheme_info.tables_procedures_query or scheme_info.procedures_query
    bridge.run_many({ schemas.command_spec(entry.conn, scheme_info, query) }, function(results)
      local routine_rows = scheme_info.parse_results(schemas.result_lines(results[1]), 3)
      self:apply_routines(entry, scheme_info, routine_rows)
      self.render()
    end)
  end
  entry.loading = false
  spinner.stop(entry.key_name)
  self.render()
end

M.Introspect = Introspect
return M
