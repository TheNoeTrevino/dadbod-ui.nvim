---@mod dadbod-ui.state  Central instance: discovered connections and paths
---
--- Holds the discovered connection list and a map of per-connection entries
--- keyed by `key_name`. UI and schema state (tables, schemas, buffers, the live
--- connection handle) are layered on by later milestones; this milestone owns
--- identity, paths, and the public connection list.

local connections = require('dadbod-ui.connections')
local bridge = require('dadbod-ui.bridge')

local M = {}

---@class DadbodUI.Instance
---@field config DadbodUI.Config
---@field save_path string         resolved save dir ('' when unset)
---@field connections_path string|nil
---@field tmp_location string      resolved tmp-query dir ('' when unset)
---@field dbs_list DadbodUI.ConnectionRecord[]  discovered connection records
---@field dbs table<string, DadbodUI.ConnectionEntry>  entries keyed by key_name
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
  self.dbs_list = connections.discover(self.config, inputs)
  self.dbs = {}
  for _, record in ipairs(self.dbs_list) do
    self.dbs[record.key_name] = make_entry(record, self.save_path)
  end
  return self
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
return M
