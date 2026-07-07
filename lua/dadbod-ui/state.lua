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
---@field tmp_location string      resolved tmp-query dir (the session temp dir when unconfigured)
---@field dbs_list DadbodUI.ConnectionRecord[]  discovered connection records
---@field dbs table<string, DadbodUI.ConnectionEntry>  entries keyed by key_name
---@field dbout_list table<string, string>  executed result files -> preview content
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
  return vim.fs.abspath(vim.fs.normalize(path))
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
--- The files in `dir` (a connection's tmp query folder), sorted. A plain
--- directory listing -- NOT a glob, whose pattern magic would misread
--- connection names containing `[`/`?`/`*`. Empty when the folder doesn't
--- exist yet.
---@param dir string
---@return string[]
local function list_dir(dir)
  local files = vim
    .iter(vim.fs.dir(dir))
    :filter(function(_, kind)
      return kind == 'file'
    end)
    :map(function(name)
      return dir .. '/' .. name
    end)
    :totable()
  table.sort(files)
  return files
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
---@param tmp_location string
---@return DadbodUI.ConnectionEntry
local function make_entry(record, save_path, config, tmp_location)
  local parsed = bridge.parse_url(record.url)
  local scheme = parsed.scheme or ''
  local scheme_info = schemas.get(scheme, config)
  local db_name = (parsed.path or ''):gsub('^/', '')
  -- The group-qualified identifier names the save folder AND the tmp query
  -- folder for this specific connection, so a name reused across groups never
  -- collides on disk or resolves back to the wrong db (see utils.qualified_name).
  local save_name = utils.qualified_name(record.name, record.group)
  local tmp_path = tmp_location .. '/' .. save_name
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
    tmp_path = tmp_path,
    conn = nil, -- live connection handle, set when connected
    conn_tried = false,
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
    -- Pure domain containers: drawer expand/collapse state lives in the
    -- drawer's `expand` map (see drawer/ids.lua), never on these.
    tables = {},
    schemas = { list = {}, items = {} },
    routines = { list = {}, items = {}, flat = {} },
    -- Scratch buffers persist (and are restored from tmp_path) only when the
    -- user configured a tmp-query location; the session-temp fallback dir is
    -- never restored from.
    buffers = config.tmp_query_location ~= '' and list_dir(tmp_path) or {},
    saved_queries = {},
  }
end

--- Create a new instance from resolved config (does not populate yet). An
--- unset tmp-query location falls back to Neovim's session temp directory, so
--- scratch buffers always use the same per-connection-folder mechanism -- the
--- fallback is merely session-local (wiped with the session, never restored).
---@param config DadbodUI.Config
---@return DadbodUI.Instance
function M.new(config)
  local tmp_location = expand_dir(config.tmp_query_location)
  if tmp_location == '' then
    tmp_location = vim.fs.dirname(vim.fn.tempname())
  end
  return setmetatable({
    config = config,
    save_path = expand_dir(config.save_location),
    connections_path = connections.connections_path(config.save_location),
    tmp_location = tmp_location,
    dbs_list = {},
    dbs = {},
    dbout_list = {},
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
    -- interactive state (live handle, introspected schemas/tables)
    -- must survive an unrelated edit. Only new or url-changed connections are
    -- rebuilt -- which also avoids re-running make_entry's bridge calls for
    -- every connection on each repopulate.
    local prev = previous[record.key_name]
    if prev ~= nil and prev.url == record.url then
      self.dbs[record.key_name] = prev
    else
      self.dbs[record.key_name] = make_entry(record, self.save_path, self.config, self.tmp_location)
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

--- Whether `buf` (a buffer file path) is a scratch query buffer: it lives
--- under the tmp-query location (configured or the session-temp fallback).
---@param buf string
---@return boolean
function Instance:is_tmp_location_buffer(buf)
  return buf:find('^' .. vim.pesc(self.tmp_location) .. '/') ~= nil
end

--- The connection entry owning `dir`, or nil. Ownership is recorded by
--- directory: a connection's scratch buffers live in `entry.tmp_path` and its
--- saved queries in `entry.save_path`, so a buffer's parent directory resolves
--- it to its connection (backs the drawer's find_buffer adoption).
---@param dir string  absolute directory path
---@return DadbodUI.ConnectionEntry|nil
function Instance:entry_for_dir(dir)
  -- Iterating a dict, so find yields (key_name, entry); keep the entry.
  local _, entry = vim.iter(self.dbs):find(function(_, e)
    return dir == e.tmp_path or (e.save_path ~= '' and dir == e.save_path)
  end)
  return entry
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
---@param opts? DadbodUI.Config
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
