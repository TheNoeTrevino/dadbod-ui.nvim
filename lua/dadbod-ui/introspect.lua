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
local state = require('dadbod-ui.state')

local M = {}

---@class DadbodUI.Introspect
---@field config DadbodUI.Config
---@field connector fun(url: string): string  connect backend (injectable for specs)
---@field render fun(): nil  re-render callback (the drawer's render)
local Introspect = {}
Introspect.__index = Introspect

--- Build an introspection controller. `connector` is dadbod's connect (injectable
--- so specs run offline); `render` is invoked after async schema/table data lands
--- (connecting and saved-query refresh never render).
---@param opts { config: DadbodUI.Config, connector: fun(url: string): string, render: fun(): nil }
---@return DadbodUI.Introspect
function M.new(opts)
  return setmetatable({
    config = opts.config,
    connector = opts.connector,
    render = opts.render,
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
  local notify = require('dadbod-ui.notifications')
  notify.info(string.format('Connecting to db %s...', entry.name))
  local started = vim.uv.hrtime()
  local ok, conn = pcall(self.connector, entry.url)
  if ok then
    entry.conn = conn
    entry.conn_error = ''
    local elapsed_ms = math.floor((vim.uv.hrtime() - started) / 1e6 + 0.5)
    notify.info(string.format('Connected to db %s. Took %dms to connect.', entry.name, elapsed_ms))
  else
    entry.conn = ''
    entry.conn_error = tostring(conn)
    notify.error(string.format('Error connecting to db %s: %s', entry.name, tostring(conn)))
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

--- Connect then introspect a connection on expand.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Introspect:expand_db(entry)
  self:load_saved_queries(entry)
  self:connect(entry)
  if not state.is_connected(entry) then
    return
  end
  if entry.schema_support then
    self:populate_schemas(entry)
  else
    -- Defer so the initial expand render paints before the (blocking) adapter
    -- call; keeps the keypress responsive even for the tables-only path.
    vim.schedule(function()
      self:populate_tables(entry)
    end)
  end
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
    return
  end
  local scheme_info = schemas.get(entry.scheme, self.config)
  local specs = {
    schemas.command_spec(entry.conn, scheme_info, scheme_info.schemes_query),
    schemas.command_spec(entry.conn, scheme_info, scheme_info.schemes_tables_query),
  }
  bridge.run_many(specs, function(results)
    local schema_list = scheme_info.parse_results(schemas.result_lines(results[1]), 1)
    local table_rows = scheme_info.parse_results(schemas.result_lines(results[2]), 2)
    self:apply_schemas(entry, schema_list, table_rows)
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

--- Introspect tables for a non-schema adapter (e.g. sqlite) via dadbod's
--- `tables` adapter call and render. Port of `populate_tables`, including the
--- sqlite whitespace fix and the mysql warning filter.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Introspect:populate_tables(entry)
  entry.tables.list = {}
  if not state.is_connected(entry) then
    return
  end
  local raw = bridge.adapter_call(entry.conn, 'tables', { entry.conn }, {})
  entry.tables.list = schemas.normalize_table_list(entry.scheme, raw)
  self:populate_table_items(entry.tables)
  self.render()
end

M.Introspect = Introspect
return M
