---@mod dadbod-ui.connections  Connection discovery and the connections.json store
---
--- Connections come from four sources, merged in precedence order
--- (dotenv → env → g:db/g:dbs → connections.json); the first occurrence of a
--- given (name, source, group) wins. Each is normalized into a record:
---   { name, url, source, group, key_name }
--- where `url` is resolved through dadbod and `key_name` namespaces the record
--- by group so the same name can exist in different groups.

local bridge = require('dadbod-ui.bridge')

local M = {}

--- Namespacing key: `name_source`, or `group_name_source` when grouped.
---@param name string
---@param source string
---@param group string|nil
---@return string
function M.key_name(name, source, group)
  if group == nil or group == '' then
    return string.format('%s_%s', name, source)
  end
  return string.format('%s_%s_%s', group, name, source)
end

--- Normalize a discovered connection into a record (url resolved at storage
--- time, matching the original).
---@param name string
---@param url string
---@param source string
---@param group string|nil
---@return DadbodUI.ConnectionRecord
local function record(name, url, source, group)
  group = group or ''
  return {
    name = name,
    url = bridge.resolve(url),
    source = source,
    group = group,
    key_name = M.key_name(name, source, group),
  }
end
M.record = record

-- A g:db / g:dbs value may be a plain url or a funcref returning one.
---@param value any
---@return string
local function resolve_var(value)
  if type(value) == 'string' then
    return value
  end
  if vim.is_callable(value) then
    return value()
  end
  error('invalid global variable database url type: ' .. type(value))
end

---@param url string
---@return string
local function last_segment(url)
  local parts = vim.split(url, '/', { plain = true })
  return parts[#parts]
end

--- Records from `g:db` (single) and `g:dbs` (dict or array; urls may be
--- funcrefs). Array entries are `{ name, url, group? }`.
---@param g_db any
---@param g_dbs any
---@return DadbodUI.ConnectionRecord[]
function M.from_global(g_db, g_dbs)
  local out = {}
  if g_db ~= nil and g_db ~= '' then
    local url = resolve_var(g_db)
    out[#out + 1] = record(last_segment(url), url, 'g:dbs')
  end
  if type(g_dbs) ~= 'table' or vim.tbl_isempty(g_dbs) then
    return out
  end
  if vim.islist(g_dbs) then
    for _, db in ipairs(g_dbs) do
      out[#out + 1] = record(db.name, resolve_var(db.url), 'g:dbs', db.group)
    end
  else
    for name, url in pairs(g_dbs) do
      out[#out + 1] = record(name, resolve_var(url), 'g:dbs')
    end
  end
  return out
end

--- Record from the env source (`DBUI_URL` / `DBUI_NAME`). The name falls back to
--- the last url path segment.
---@param env table<string, string>   name->value map (e.g. vim.fn.environ())
---@param config DadbodUI.Config
---@return DadbodUI.ConnectionRecord[]    0 or 1 record
function M.from_env(env, config)
  local url = env[config.env_variable_url]
  if url == nil or url == '' then
    return {}
  end
  local name = env[config.env_variable_name]
  if name == nil or name == '' then
    name = last_segment(url)
  end
  if name == '' then
    return {}
  end
  return { record(name, url, 'env') }
end

--- Records from env vars containing the configured prefix (default `DB_UI_`).
--- The connection name is the var with the prefix stripped, lowercased.
---@param env table<string, string>
---@param config DadbodUI.Config
---@return DadbodUI.ConnectionRecord[]
function M.from_dotenv(env, config)
  local prefix = config.dotenv_variable_prefix
  local out = {}
  for name, url in pairs(env) do
    if name:find(prefix, 1, true) then
      local db_name = name:gsub(vim.pesc(prefix), ''):lower()
      out[#out + 1] = record(db_name, url, 'dotenv')
    end
  end
  return out
end

--- Records from a decoded connections.json array (`{ name, url, group? }`).
---@param entries DadbodUI.FileConnection[]
---@return DadbodUI.ConnectionRecord[]
function M.from_file(entries)
  local out = {}
  for _, conn in ipairs(entries) do
    out[#out + 1] = record(conn.name, conn.url, 'file', conn.group)
  end
  return out
end

--- Deduplicate by (name, source, group); first occurrence wins. `on_dup` is
--- called for each dropped duplicate (used later for a warning notification).
---@param records DadbodUI.ConnectionRecord[]
---@param on_dup? fun(name: string, source: string)
---@return DadbodUI.ConnectionRecord[]
function M.dedup(records, on_dup)
  local seen, out = {}, {}
  for _, r in ipairs(records) do
    local id = M.key_name(r.name, r.source, r.group)
    if seen[id] then
      if on_dup then
        on_dup(r.name, r.source)
      end
    else
      seen[id] = true
      out[#out + 1] = r
    end
  end
  return out
end

--- Path to the connections.json store, or nil when no save location is set.
---@param save_location string|nil
---@return string|nil
function M.connections_path(save_location)
  if save_location == nil or save_location == '' then
    return nil
  end
  local folder = (vim.fn.fnamemodify(save_location, ':p'):gsub('/$', ''))
  return folder .. '/connections.json'
end

--- Read a connections.json array. Returns `{}` when missing or not a valid json
--- array (the original also warns; that surfaces once notifications land).
---@param path string|nil
---@return DadbodUI.FileConnection[]
function M.read_file(path)
  if path == nil or vim.fn.filereadable(path) == 0 then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), '\n'))
  if not ok or type(decoded) ~= 'table' then
    return {}
  end
  if not vim.islist(decoded) and not vim.tbl_isempty(decoded) then
    return {} -- a json object, not an array
  end
  return decoded
end

--- Write a connections list to `path` as a json array, creating the parent
--- directory. Entries are plain `{ name, url, group? }`.
---@param path string
---@param list DadbodUI.FileConnection[]
function M.write_file(path, list)
  local dir = vim.fn.fnamemodify(path, ':h')
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p')
  end
  vim.fn.writefile({ vim.json.encode(list) }, path)
end

-- Two stored connections are "the same" when names match (case-insensitive) and
-- their urls resolve equal -- mirrors the original delete/rename matching.
---@param conn DadbodUI.FileConnection
---@param name string
---@param resolved_url string
---@return boolean
local function same_conn(conn, name, resolved_url)
  return conn.name:lower() == name:lower() and bridge.resolve(conn.url):lower() == resolved_url
end

--- Append a connection. Returns `(new_list, nil)` or `(nil, err)` when a
--- connection with that name already exists (case-insensitive).
---@param list DadbodUI.FileConnection[]
---@param name string
---@param url string
---@return DadbodUI.FileConnection[]|nil, string|nil
function M.add_connection(list, name, url)
  for _, conn in ipairs(list) do
    if conn.name:lower() == name:lower() then
      return nil, 'Connection with that name already exists. Please enter different name.'
    end
  end
  local out = vim.deepcopy(list)
  out[#out + 1] = { name = name, url = url }
  return out, nil
end

--- Remove the connection matching (name, url). Returns a new list.
---@param list DadbodUI.FileConnection[]
---@param name string
---@param url string
---@return DadbodUI.FileConnection[]
function M.delete_connection(list, name, url)
  local resolved = bridge.resolve(url):lower()
  local out = {}
  for _, conn in ipairs(list) do
    if not same_conn(conn, name, resolved) then
      out[#out + 1] = conn
    end
  end
  return out
end

--- Replace the connection matching (old_name, old_url) with (new_name, new_url),
--- preserving its group. Returns a new list (unchanged when no match).
---@param list DadbodUI.FileConnection[]
---@param old_name string
---@param old_url string
---@param new_name string
---@param new_url string
---@return DadbodUI.FileConnection[]
function M.rename_connection(list, old_name, old_url, new_name, new_url)
  local resolved = bridge.resolve(old_url):lower()
  local out = vim.deepcopy(list)
  for i, conn in ipairs(out) do
    if same_conn(conn, old_name, resolved) then
      local entry = { name = new_name, url = new_url }
      if conn.group ~= nil and conn.group ~= '' then
        entry.group = conn.group
      end
      out[i] = entry
      break
    end
  end
  return out
end

--- Discover all connections, merged in precedence order with duplicates dropped.
--- `inputs` lets callers (and tests) inject sources; anything omitted is read
--- from the live environment / globals / file.
---@param config DadbodUI.Config
---@param inputs? DadbodUI.DiscoverInputs
---@return DadbodUI.ConnectionRecord[]
function M.discover(config, inputs)
  inputs = inputs or {}
  local env = inputs.env or vim.fn.environ()
  local g_db = inputs.g_db
  if g_db == nil then
    g_db = vim.g.db
  end
  local g_dbs = inputs.g_dbs
  if g_dbs == nil then
    g_dbs = vim.g.dbs
  end
  local file_entries = inputs.file_entries
  if file_entries == nil then
    file_entries = M.read_file(M.connections_path(config.save_location))
  end

  local all = {}
  vim.list_extend(all, M.from_dotenv(env, config))
  vim.list_extend(all, M.from_env(env, config))
  vim.list_extend(all, M.from_global(g_db, g_dbs))
  vim.list_extend(all, M.from_file(file_entries))
  return M.dedup(all, inputs.on_dup)
end

return M
