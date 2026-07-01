---@mod dadbod-ui.introspect  Connect + schema/table introspection for a connection
---
--- Connects a connection (sync, as dadbod does) and introspects its
--- schemas/tables, folding the results into the connection `entry` and
--- re-rendering. It operates purely on the entry plus the adapter metadata in
--- `schemas`, so it never requires `drawer` or `query` -- the dependency graph
--- stays acyclic and `state` remains the sink. The drawer (and the query
--- controller) build one of these, injecting the connect backend and a render
--- callback.
---
--- Introspection is non-blocking: schema-supporting adapters fan their schema-
--- list and table-list queries out concurrently via `bridge.run_many`; the
--- tables-only path uses dadbod's `tables` adapter call. Each path re-renders
--- once its data lands, so a large database never freezes the UI.

local bridge = require('dadbod-ui.bridge')
local schemas = require('dadbod-ui.schemas')
local spinner = require('dadbod-ui.spinner')
local spinners = require('dadbod-ui.spinners')
local state = require('dadbod-ui.state')

local M = {}

---@class DadbodUI.Introspect
---@field config DadbodUI.Config
---@field connector fun(url: string): string  connect backend (injectable for specs)
---@field render fun(): nil  re-render callback (the drawer's render)
---@field repaint fun(key_name: string, frame: string): nil  single-line db-node repaint (the drawer's repaint_db_node); animates the loading spinner without a full render
local Introspect = {}
Introspect.__index = Introspect

--- Build an introspection controller. `connector` is dadbod's connect (injectable
--- so specs run offline); `render` is invoked after async schema/table data lands
--- (connecting and saved-query refresh never render). `repaint` drives the
--- per-frame loading animation on a single db node (defaults to a no-op so a
--- controller built without it -- e.g. the query controller -- never crashes).
---@param opts { config: DadbodUI.Config, connector: fun(url: string): string, render: fun(): nil, repaint?: fun(key_name: string, frame: string): nil }
---@return DadbodUI.Introspect
function M.new(opts)
  return setmetatable({
    config = opts.config,
    connector = opts.connector,
    render = opts.render,
    repaint = opts.repaint or function() end,
  }, Introspect)
end

--- Connect a connection if not already connected. Errors are captured on the
--- entry (surfaced as the error icon) and notified, mirroring the original.
---@param entry DadbodUI.ConnectionEntry
---@return DadbodUI.ConnectionEntry
function Introspect:connect(entry)
  if state.is_connected(entry) then
    return entry
  end
  -- No "Connecting..." notification: the drawer's inline loading indicator on
  -- the db node communicates progress. Success is silent too -- the connection_ok
  -- icon signals it and the elapsed time lands in the details view (`H`) rather
  -- than a popup. Only a failure interrupts with a notification.
  local started = vim.uv.hrtime()
  local ok, conn = pcall(self.connector, entry.url)
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
  return entry
end

--- Introspect a connected entry: schema-supporting adapters fan out their
--- schema/table queries, the rest list tables directly. Port of
--- `drawer.populate`.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Introspect:populate(entry)
  if entry.schema_support then
    self:populate_schemas(entry)
  else
    self:populate_tables(entry)
  end
end

--- Connect then introspect a connection on expand. `bridge.connect` is
--- SYNCHRONOUS and blocks Neovim, so we paint the static loading indicator first
--- (mark `loading` + render) and only THEN `vim.schedule` the blocking connect --
--- the same deferral the tables path already used -- so the frame is visible
--- before the freeze. The animated spinner can only run during the async
--- `run_many` window of `populate_schemas`; the blocking connect + sqlite table
--- fetch show the static frame only (a timer can't tick while the loop is blocked).
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Introspect:expand_db(entry)
  self:load_saved_queries(entry)
  entry.loading = true
  self.render()
  vim.schedule(function()
    self:connect(entry)
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
--- Port of `s:drawer.load_saved_queries`. Lives here so the query controller can
--- refresh saved queries without reaching back through the drawer.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Introspect:load_saved_queries(entry)
  if entry.save_path ~= '' then
    entry.saved_queries.list = vim.fn.glob(entry.save_path .. '/*', true, true)
  end
end

--- Whether `schema_name` matches any `hide_schemas` pattern (Vim regexes, as in
--- the original).
---@param schema_name string
---@return boolean
function Introspect:_is_schema_ignored(schema_name)
  return vim.iter(self.config.hide_schemas):any(function(pattern)
    return vim.fn.match(schema_name, pattern) > -1
  end)
end

--- Ensure every table in `tables.list` has an expand-state item, preserving the
--- existing ones (so a refresh keeps tables expanded). Port of
--- `populate_table_items`.
---@param tables DadbodUI.TablesNode
---@return nil
function Introspect:populate_table_items(tables)
  for _, table_name in ipairs(tables.list) do
    if tables.items[table_name] == nil then
      tables.items[table_name] = { expanded = false }
    end
  end
end

--- Introspect schemas + tables concurrently and render. Port of
--- `populate_schemas`, with the two queries fanned out via `run_many`.
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
--- `hide_schemas`. Port of the body of `populate_schemas`: tables are grouped
--- per schema and also collected into the flat `entry.tables.list`.
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
  for _, schema in ipairs(visible_schemas) do
    if entry.schemas.items[schema] == nil then
      entry.schemas.items[schema] = {
        expanded = false,
        tables = { expanded = true, list = {}, items = {} },
      }
    end
    local schema_tables = tables_by_schema[schema] or {}
    table.sort(schema_tables)
    entry.schemas.items[schema].tables.list = schema_tables
    self:populate_table_items(entry.schemas.items[schema].tables)
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
--- adapters collect every routine into `entry.routines.flat`. Divergence from
--- upstream vim-dadbod-ui, which lists no procedures/functions at all -- this is
--- the first DBeaver-style object-introspection feature (see the commit message).
---@param entry DadbodUI.ConnectionEntry
---@param scheme_info DadbodUI.SchemaAdapter
---@param routine_rows string[][]
---@return nil
function Introspect:apply_routines(entry, scheme_info, routine_rows)
  if entry.schema_support then
    -- Build a fresh items table in one pass: schemas that no longer have routines
    -- simply never enter it (pruning), and each new bucket inherits the previous
    -- node's expand state. `order` preserves first-seen schema order for the drawer.
    local old_items = entry.routines.items
    local items, order = {}, {}
    for _, row in ipairs(routine_rows) do
      local schema_name, name, kind = row[1], row[2], row[3]
      if not self:_is_schema_ignored(schema_name) then
        if items[schema_name] == nil then
          local existing = old_items[schema_name]
          items[schema_name] = { expanded = existing ~= nil and existing.expanded or false, list = {} }
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
--- `tables` adapter call and render. Port of `populate_tables`, including the
--- sqlite whitespace fix and the mysql warning filter. When the adapter also
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
  self:populate_table_items(entry.tables)
  local scheme_info = schemas.get(entry.scheme, self.config)
  if entry.routine_support then
    -- Routines aren't part of dadbod's `tables` call, so fetch them separately and
    -- non-blockingly; the tree renders now and fills in the Procedures node on land.
    bridge.run_many({ schemas.command_spec(entry.conn, scheme_info, scheme_info.procedures_query) }, function(results)
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
