---@mod dadbod-ui.state  Central instance: discovered connections and paths
---
--- Holds the discovered connection list and a map of per-connection entries
--- keyed by `key_name`. UI and schema state (tables, schemas, buffers, the live
--- connection handle) are layered on by later milestones; this milestone owns
--- identity, paths, and the public connection list.

local connections = require('dadbod-ui.connections')
local bridge = require('dadbod-ui.bridge')
local config_mod = require('dadbod-ui.config')

local M = {}

---@class DadbodUI.Instance
---@field config DadbodUI.Config
---@field save_path string         resolved save dir ('' when unset)
---@field connections_path string|nil
---@field tmp_location string      resolved tmp-query dir ('' when unset)
---@field dbs_list DadbodUI.ConnectionRecord[]  discovered connection records
---@field dbs table<string, DadbodUI.ConnectionEntry>  entries keyed by key_name
---@field _inputs? DadbodUI.DiscoverInputs  inputs last populated with (for repopulate)
local Instance = {}
Instance.__index = Instance

---@param path string|nil
---@return string
local function expand_dir(path)
  if path == nil or path == '' then
    return ''
  end
  return (vim.fn.fnamemodify(path, ':p'):gsub('/$', ''))
end

--- Build a data entry for a discovered connection. Schema/UI fields are added by
--- later milestones; this captures identity, scheme, db name and save path.
---@param record DadbodUI.ConnectionRecord
---@param save_path string
---@return DadbodUI.ConnectionEntry
local function make_entry(record, save_path)
  local parsed = bridge.parse_url(record.url)
  local db_name = (parsed.path or ''):gsub('^/', '')
  local save_name = record.group ~= '' and (record.group .. '_' .. record.name) or record.name
  return {
    url = record.url,
    source = record.source,
    name = record.name,
    group = record.group,
    key_name = record.key_name,
    scheme = parsed.scheme or '',
    db_name = db_name ~= '' and db_name or record.name,
    save_path = save_path ~= '' and (save_path .. '/' .. save_name) or '',
    conn = nil, -- live connection handle, set when connected (later milestone)
    expanded = false, -- drawer expand/collapse state
  }
end

--- Create a new instance from resolved config (does not populate yet).
---@param config DadbodUI.Config
---@return DadbodUI.Instance
function M.new(config)
  local save_path = expand_dir(config.save_location)
  return setmetatable({
    config = config,
    save_path = save_path,
    connections_path = connections.connections_path(config.save_location),
    tmp_location = expand_dir(config.tmp_query_location),
    dbs_list = {},
    dbs = {},
  }, Instance)
end

--- Discover connections and (re)build the entry map. `inputs` is forwarded to
--- `connections.discover` (used by tests to inject sources).
---@param inputs? DadbodUI.DiscoverInputs
---@return DadbodUI.Instance
function Instance:populate(inputs)
  self._inputs = inputs
  self.dbs_list = connections.discover(self.config, inputs)
  self.dbs = {}
  for _, record in ipairs(self.dbs_list) do
    self.dbs[record.key_name] = make_entry(record, self.save_path)
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

--- List connections with their connection state.
---@return DadbodUI.ConnectionInfo[]
function Instance:connections_list()
  return vim.tbl_map(function(r)
    local entry = self.dbs[r.key_name]
    return {
      name = r.name,
      url = r.url,
      is_connected = entry ~= nil and entry.conn ~= nil,
      source = r.source,
    }
  end, self.dbs_list)
end

M.Instance = Instance

-- Singleton: the current session's config and instance. This module is the
-- single source of truth other modules reach via `state.get()`; it never
-- requires drawer/query/dbout, so the dependency graph stays acyclic.
local current_config = nil
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
