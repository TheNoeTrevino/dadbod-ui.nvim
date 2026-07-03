-- Central instance: discovered connections and paths
--
-- Holds the discovered connection list and a map of per-connection entries
-- keyed by `key_name`. UI and schema state (tables, schemas, buffers, the live
-- connection handle) are layered on by later milestones; this milestone owns
-- identity, paths, and the public connection list.

---@class DadbodUI.StateModule
---@field new fun(config: DadbodUI.Config): DadbodUI.Instance
---@field is_connected fun(entry: DadbodUI.ConnectionEntry): boolean
---@field disconnect fun(entry: DadbodUI.ConnectionEntry)
---@field Instance DadbodUI.Instance
---@field setup fun(opts?: table): DadbodUI.Config
---@field config fun(): DadbodUI.Config
---@field get fun(): DadbodUI.Instance
---@field reset fun()

---@private
local connections = require('dadbod-ui.connections')
---@private
local bridge = require('dadbod-ui.bridge')
---@private
local config_mod = require('dadbod-ui.config')
---@private
local schemas = require('dadbod-ui.schemas')
---@private
local table_helpers = require('dadbod-ui.table_helpers')
---@private
local utils = require('dadbod-ui.utils')

---@type DadbodUI.StateModule
---@diagnostic disable-next-line: missing-fields
local M = {}

---@class DadbodUI.Instance
---@field config DadbodUI.Config
---@field save_path string         resolved save dir ('' when unset)
---@field connections_path string|nil
---@field tmp_location string      resolved tmp-query dir ('' when unset)
---@field dbs_list DadbodUI.ConnectionRecord[]  discovered connection records
---@field dbs table<string, DadbodUI.ConnectionEntry>  entries keyed by key_name
---@field dbout_list table<string, string>  executed result files -> preview content
---@field old_buffers string[]  tmp-location query files found at startup (restored per-entry)
---@field _inputs? DadbodUI.DiscoverInputs  inputs last populated with (for repopulate)
local Instance = {}
Instance.__index = Instance

---@private
---@param path string|nil
---@return string
local function expand_dir(path)
  if path == nil or path == '' then
    return ''
  end
  return (vim.fn.fnamemodify(path, ':p'):gsub('/$', ''))
end

---@private
--- The adapter's canonical query-input file extension (`sql` for
--- postgres/mysql/sqlite, adapter-specific otherwise), defaulting to `sql` when
--- dadbod can't answer. This is the extension a genuine query file for the
--- adapter would carry, so naming generated buffers with it makes external SQL
--- tooling (formatters/linters/LSP that key off the filename) attach and run.
---@param url string
---@return string
local function resolve_extension(url)
  local ok, ext = pcall(bridge.input_extension, url)
  return (ok and ext ~= '') and ext or 'sql'
end

---@private
--- The query-buffer filetype for an adapter: the schema metadata's own filetype
--- if it declares one, else dadbod's input extension (mongodb's `js` is mapped
--- to `javascript`), defaulting to `sql`. Note this may differ from
--- `resolve_extension` (e.g.
--- mysql/plsql filetypes over a `sql` extension) -- the extension names the file,
--- the filetype drives Neovim's syntax/behaviour.
---@param url string
---@param scheme_info DadbodUI.SchemaAdapter
---@return string
local function resolve_filetype(url, scheme_info)
  local filetype = scheme_info.filetype
  if filetype == nil or filetype == '' then
    filetype = resolve_extension(url)
  end
  if filetype == 'js' then
    return 'javascript'
  end
  return filetype
end

---@private
--- Tmp-location query files belonging to `name`: a startup buffer is restored
--- under a connection when its basename (or extension, for `db_ui.<name>` style
--- names) starts with `<slug(name)>-`. The prefix must be the SLUG of the name
--- (as `query.generate_buffer_name` and `drawer:get_buffer_name` both use), so a
--- connection named e.g. "My DB" -- whose files are `mydb-...` -- still restores
--- its tmp buffers.
---@param old_buffers string[]
---@param name string
---@return string[]
local function buffers_for(old_buffers, name)
  local prefix = '^' .. vim.pesc(utils.slug(name)) .. '%-'
  return vim.tbl_filter(function(path)
    local tail = vim.fs.basename(path)
    local ext = vim.fn.fnamemodify(path, ':e')
    return tail:find(prefix) ~= nil or ext:find(prefix) ~= nil
  end, old_buffers)
end

---@private
--- Build a data entry for a discovered connection. Captures identity, scheme,
--- db name, save path and the adapter's schema metadata (schema support, quote
--- rules, default scheme, filetype, table helpers). The schema/table *contents*
--- are introspected lazily by the drawer on expand; here we only seed the empty
--- containers.
---@param record DadbodUI.ConnectionRecord
---@param save_path string
---@param config DadbodUI.Config
---@param old_buffers string[]
---@return DadbodUI.ConnectionEntry
local function make_entry(record, save_path, config, old_buffers)
  local parsed = bridge.parse_url(record.url)
  local scheme = parsed.scheme or ''
  local scheme_info = schemas.get(scheme, config)
  local db_name = (parsed.path or ''):gsub('^/', '')
  -- The group-qualified identifier ties the save folder AND the tmp query-buffer
  -- files to this specific connection, so a name reused across groups never
  -- collides on disk or resolves back to the wrong db (see utils.qualified_name).
  local save_name = utils.qualified_name(record.name, record.group)
  return {
    url = record.url,
    source = record.source,
    name = record.name,
    group = record.group,
    key_name = record.key_name,
    save_name = save_name,
    scheme = scheme,
    db_name = db_name ~= '' and db_name or record.name,
    save_path = save_path ~= '' and (save_path .. '/' .. save_name) or '',
    conn = nil, -- live connection handle, set when connected
    conn_tried = false,
    expanded = false, -- drawer expand/collapse state
    schema_support = schemas.supports_schemes(scheme_info, parsed),
    -- Whether the adapter can list stored procedures/functions (a `procedures_query`
    -- is defined). Adapters without one -- notably sqlite, which has no stored
    -- routines -- introspect no routines and render no Procedures node.
    routine_support = scheme_info.procedures_query ~= nil and scheme_info.procedures_query ~= '',
    quote = scheme_info.quote ~= nil and scheme_info.quote ~= 0,
    default_scheme = scheme_info.default_scheme or '',
    filetype = resolve_filetype(record.url, scheme_info),
    extension = resolve_extension(record.url),
    table_helpers = table_helpers.get(scheme, config),
    tables = { expanded = false, list = {}, items = {} },
    schemas = { expanded = false, list = {}, items = {} },
    routines = { expanded = false, list = {}, items = {}, flat = {} },
    buffers = { expanded = false, list = buffers_for(old_buffers, save_name), tmp = {} },
    saved_queries = { expanded = false, list = {} },
  }
end

--- Create a new instance from resolved config (does not populate yet). When a
--- tmp-query location is configured we ensure it exists and snapshot the query
--- files already in it, so connections can restore their open buffers on the
--- next populate.
---@param config DadbodUI.Config
---@return DadbodUI.Instance
function M.new(config)
  local save_path = expand_dir(config.save_location)
  local tmp_location = expand_dir(config.tmp_query_location)
  local old_buffers = {}
  if tmp_location ~= '' then
    if not utils.is_dir(tmp_location) then
      vim.fn.mkdir(tmp_location, 'p')
    end
    old_buffers = vim.fn.glob(tmp_location .. '/*', true, true)
  end
  return setmetatable({
    config = config,
    save_path = save_path,
    connections_path = connections.connections_path(config.save_location),
    tmp_location = tmp_location,
    dbs_list = {},
    dbs = {},
    dbout_list = {},
    old_buffers = old_buffers,
  }, Instance)
end

--- Discover connections and (re)build the entry map. `inputs` is forwarded to
--- `connections.discover` (used by tests to inject sources).
---@param inputs? DadbodUI.DiscoverInputs
---@return DadbodUI.Instance
function Instance:populate(inputs)
  self._inputs = inputs
  local previous = self.dbs
  self.dbs_list = connections.discover(self.config, inputs)
  self.dbs = {}
  for _, record in ipairs(self.dbs_list) do
    -- An unchanged connection (same key_name and url) keeps its existing entry
    -- as-is: the static metadata is a pure function of (url, config) and the
    -- interactive state (expanded, live handle, introspected schemas/tables)
    -- must survive an unrelated edit. Only new or url-changed connections are
    -- rebuilt -- which also avoids re-running make_entry's bridge calls for
    -- every connection on each repopulate.
    local prev = previous[record.key_name]
    if prev ~= nil and prev.url == record.url then
      self.dbs[record.key_name] = prev
    else
      self.dbs[record.key_name] = make_entry(record, self.save_path, self.config, self.old_buffers)
    end
  end
  return self
end

--- Re-discover and rebuild the entry map after the connections.json store
--- changed on disk. Reuses any injected env/globals from the last `populate`
--- (so tests stay deterministic) but forces the file to be re-read.
---@return DadbodUI.Instance
function Instance:repopulate()
  local inputs = {}
  if self._inputs ~= nil then
    inputs = vim.tbl_extend('force', {}, self._inputs)
  end
  inputs.file_entries = nil
  return self:populate(inputs)
end

--- Whether `buf` (a buffer file path) belongs to the tmp-query location for
--- `entry`: either it was generated into the entry's `buffers.tmp` list, or it
--- lives under the configured `tmp_location`.
---@param entry DadbodUI.ConnectionEntry
---@param buf string
---@return boolean
function Instance:is_tmp_location_buffer(entry, buf)
  if vim.tbl_contains(entry.buffers.tmp, buf) then
    return true
  end
  return self.tmp_location ~= '' and buf:find('^' .. vim.pesc(self.tmp_location)) ~= nil
end

--- Whether an entry holds a live connection. The `conn` field is `nil` before
--- any attempt, `''` after a FAILED attempt, and the live handle once
--- connected -- so "connected" is the non-nil, non-empty case. A failed attempt
--- must NOT report as connected.
---@param entry DadbodUI.ConnectionEntry
---@return boolean
function M.is_connected(entry)
  return entry.conn ~= nil and entry.conn ~= ''
end

--- Drop the live connection handle for `entry`, so `is_connected` reports false
--- and the next connect/query re-probes. The inverse of the introspect controller's
--- connect (`_apply_connect` sets `entry.conn`); this resets it to the pristine,
--- never-attempted state (`conn = nil`, no error). Introspected tables/schemas are
--- left intact -- this forgets the live handle, not the cached metadata. dadbod may
--- still hold a pooled connection of its own; this only clears dadbod-ui's view.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function M.disconnect(entry)
  entry.conn = nil
  entry.conn_error = ''
end

--- List connections with their connection state.
---@return DadbodUI.ConnectionInfo[]
function Instance:connections_list()
  return vim.tbl_map(function(r)
    local entry = self.dbs[r.key_name]
    return {
      name = r.name,
      group = r.group,
      key_name = r.key_name,
      url = r.url,
      is_connected = entry ~= nil and M.is_connected(entry),
      source = r.source,
    }
  end, self.dbs_list)
end

M.Instance = Instance

-- Singleton: the current session's config and instance. This module is the
-- single source of truth other modules reach via `state.get()`; it never
-- requires drawer/query/dbout, so the dependency graph stays acyclic.
---@private
local current_config = nil
---@private
local current_instance = nil

--- Resolve and store config for the session, dropping any built instance so the
--- new config takes effect on next `get()`. Returns the resolved config.
---@param opts? table
---@return DadbodUI.Config
function M.setup(opts)
  current_config = config_mod.resolve(opts)
  current_instance = nil
  return current_config
end

--- The session config (resolved from defaults/globals on first access).
---@return DadbodUI.Config
function M.config()
  if current_config == nil then
    current_config = config_mod.resolve()
  end
  return current_config
end

--- The session instance, built from discovery and cached on first access.
---@return DadbodUI.Instance
function M.get()
  if current_instance == nil then
    current_instance = M.new(M.config()):populate()
  end
  return current_instance
end

--- Drop the cached instance (next `get()` rebuilds). Used by tests/cleanup.
function M.reset()
  current_instance = nil
end

return M
