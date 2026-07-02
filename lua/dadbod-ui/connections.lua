---@mod dadbod-ui.connections  Connection discovery and the connections.json store
---
--- Connections come from four sources, merged in precedence order
--- (dotenv → env → g:db/g:dbs → connections.json); the first occurrence of a
--- given (name, source, group) wins. Each is normalized into a record:
---   { name, url, source, group, key_name }
--- where `url` is resolved through dadbod and `key_name` namespaces the record
--- by group so the same name can exist in different groups.

---@alias DadbodUI.ConnectionsOnDup fun(name: string, source: string)
---@alias DadbodUI.ConnectionsOnReadError fun(msg: string)

---@class DadbodUI.ConnectionsModule
---@field key_name fun(name: string, source: string, group: string|nil): string
---@field record fun(name: string, url: string, source: string, group: string|nil): DadbodUI.ConnectionRecord
---@field from_global fun(g_db: any, g_dbs: any): DadbodUI.ConnectionRecord[]
---@field from_env fun(env: table<string, string>, config: DadbodUI.Config): DadbodUI.ConnectionRecord[]
---@field from_dotenv fun(env: table<string, string>, config: DadbodUI.Config): DadbodUI.ConnectionRecord[]
---@field from_file fun(entries: DadbodUI.FileConnection[]): DadbodUI.ConnectionRecord[]
---@field dedup fun(records: DadbodUI.ConnectionRecord[], on_dup?: DadbodUI.ConnectionsOnDup): DadbodUI.ConnectionRecord[]
---@field connections_path fun(save_location: string|nil): string|nil
---@field read_file fun(path: string|nil, on_error?: DadbodUI.ConnectionsOnReadError): DadbodUI.FileConnection[]
---@field write_file fun(path: string, list: DadbodUI.FileConnection[])
---@field add_connection fun(list: DadbodUI.FileConnection[], name: string, url: string, group?: string): (DadbodUI.FileConnection[]|nil, string|nil)
---@field duplicate_connection fun(list: DadbodUI.FileConnection[], new_name: string, new_url: string, group?: string): (DadbodUI.FileConnection[]|nil, string|nil)
---@field delete_connection fun(list: DadbodUI.FileConnection[], name: string, url: string): DadbodUI.FileConnection[]
---@field rename_connection fun(list: DadbodUI.FileConnection[], old_name: string, old_url: string, new_name: string, new_url: string): (DadbodUI.FileConnection[]|nil, string|nil)
---@field set_group fun(list: DadbodUI.FileConnection[], name: string, url: string, group: string): (DadbodUI.FileConnection[]|nil, string|nil)
---@field move_connection fun(list: DadbodUI.FileConnection[], name: string, url: string, direction: 'up'|'down'): (DadbodUI.FileConnection[]|nil, string|nil)
---@field discover fun(config: DadbodUI.Config, inputs?: DadbodUI.DiscoverInputs): DadbodUI.ConnectionRecord[]

---@private
local bridge = require('dadbod-ui.bridge')
---@private
local utils = require('dadbod-ui.utils')

---@type DadbodUI.ConnectionsModule
---@diagnostic disable-next-line: missing-fields
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

---@private
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

---@private
---@param url string
---@return string
local function last_segment(url)
  return url:match('[^/]*$')
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
  return vim
    .iter(entries)
    :map(function(conn)
      return record(conn.name, conn.url, 'file', conn.group)
    end)
    :totable()
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

--- Read a connections.json array. Returns `{}` when missing or when the content
--- is not a valid json array. A missing file is normal (no callback); a present
--- but corrupt file invokes `on_error` so the caller can warn and avoid
--- overwriting it (the original warns here too).
---@param path string|nil
---@param on_error? fun(msg: string)
---@return DadbodUI.FileConnection[]
function M.read_file(path, on_error)
  if path == nil or not utils.is_file(path) then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), '\n'))
  local is_array = ok and type(decoded) == 'table' and (vim.islist(decoded) or vim.tbl_isempty(decoded))
  if not is_array then
    if on_error then
      on_error('Could not read connections file. Please make sure it contains a valid JSON array.')
    end
    return {}
  end
  return decoded
end

--- Write a connections list to `path` as a json array, creating the parent
--- directory. Entries are plain `{ name, url, group? }`.
---@param path string
---@param list DadbodUI.FileConnection[]
function M.write_file(path, list)
  local dir = vim.fs.dirname(path)
  if not utils.is_dir(dir) then
    vim.fn.mkdir(dir, 'p')
  end
  vim.fn.writefile({ vim.json.encode(list) }, path)
end

---@private
-- Two stored connections are "the same" when names match (case-insensitive) and
-- their urls resolve equal -- mirrors the original delete/rename matching.
---@param conn DadbodUI.FileConnection
---@param name string
---@param resolved_url string
---@return boolean
local function same_conn(conn, name, resolved_url)
  return conn.name:lower() == name:lower() and bridge.resolve(conn.url):lower() == resolved_url
end

---@private
-- Two connections occupy the same "slot" when their names match
-- (case-insensitive) AND they live in the same group -- the exact rule
-- `key_name` enforces. So the same name is allowed in different groups
-- (e.g. geekom/postgres and pi/postgres), but never twice in one group.
---@param conn DadbodUI.FileConnection
---@param name string
---@param group string
---@return boolean
local function same_slot(conn, name, group)
  return conn.name:lower() == name:lower() and (conn.group or ''):lower() == group:lower()
end

--- Append a connection in `group` ('' / nil = ungrouped). Returns
--- `(new_list, nil)`, or `(nil, err)` when a connection with that name already
--- exists *in the same group* (case-insensitive) -- the same name in a different
--- group is allowed.
---@param list DadbodUI.FileConnection[]
---@param name string
---@param url string
---@param group? string
---@return DadbodUI.FileConnection[]|nil, string|nil
function M.add_connection(list, name, url, group)
  group = group or ''
  local exists = vim.iter(list):any(function(conn)
    return same_slot(conn, name, group)
  end)
  if exists then
    return nil, 'Connection with that name already exists in that group. Please enter a different name.'
  end
  local out = vim.deepcopy(list)
  local entry = { name = name, url = url }
  if group ~= '' then
    entry.group = group
  end
  out[#out + 1] = entry
  return out, nil
end

--- Append a copy of a connection under `(new_name, new_url)` in `group`. A thin
--- alias for `add_connection` that names the intent at the call site; the
--- group-aware collision rule means a clone can keep its name as long as it lands
--- in a different group -- handy for `geekom/postgres` + `pi/postgres`.
---@param list DadbodUI.FileConnection[]
---@param new_name string
---@param new_url string
---@param group? string
---@return DadbodUI.FileConnection[]|nil, string|nil
function M.duplicate_connection(list, new_name, new_url, group)
  return M.add_connection(list, new_name, new_url, group)
end

--- Remove the connection matching (name, url). Returns a new list.
---@param list DadbodUI.FileConnection[]
---@param name string
---@param url string
---@return DadbodUI.FileConnection[]
function M.delete_connection(list, name, url)
  local resolved = bridge.resolve(url):lower()
  return vim
    .iter(list)
    :filter(function(conn)
      return not same_conn(conn, name, resolved)
    end)
    :totable()
end

--- Replace the connection matching (old_name, old_url) with (new_name, new_url),
--- preserving its group. Returns `(new_list, nil)`, or `(nil, err)` when
--- `new_name` collides with a *different* connection in the same group
--- (case-insensitive) -- which would otherwise merge two entries under one
--- `key_name` on the next discover. The list is returned unchanged (with no
--- error) when nothing matches.
---@param list DadbodUI.FileConnection[]
---@param old_name string
---@param old_url string
---@param new_name string
---@param new_url string
---@return DadbodUI.FileConnection[]|nil, string|nil
function M.rename_connection(list, old_name, old_url, new_name, new_url)
  local resolved = bridge.resolve(old_url):lower()
  local match_idx = nil
  for i, conn in ipairs(list) do
    if same_conn(conn, old_name, resolved) then
      match_idx = i
      break
    end
  end
  -- A rename keeps the entry's group, so the new name only collides within it.
  local group = match_idx ~= nil and (list[match_idx].group or '') or ''
  for i, conn in ipairs(list) do
    if i ~= match_idx and same_slot(conn, new_name, group) then
      return nil, 'Connection with that name already exists in that group. Please enter a different name.'
    end
  end
  local out = vim.deepcopy(list)
  if match_idx ~= nil then
    local entry = { name = new_name, url = new_url }
    local conn = out[match_idx]
    if conn.group ~= nil and conn.group ~= '' then
      entry.group = conn.group
    end
    out[match_idx] = entry
  end
  return out, nil
end

--- Set (or clear) the group of the connection matching (name, url). An empty
--- `group` removes it from its group. Returns `(new_list, nil)`, or `(nil, err)`
--- when another connection of the same name already lives in the target group
--- (which would merge them under one `key_name` on the next discover). The list
--- is returned unchanged (no error) when nothing matches.
---@param list DadbodUI.FileConnection[]
---@param name string
---@param url string
---@param group string
---@return DadbodUI.FileConnection[]|nil, string|nil
function M.set_group(list, name, url, group)
  local resolved = bridge.resolve(url):lower()
  local match_idx = nil
  for i, conn in ipairs(list) do
    if same_conn(conn, name, resolved) then
      match_idx = i
      break
    end
  end
  for i, conn in ipairs(list) do
    local conn_group = conn.group or ''
    if i ~= match_idx and conn.name:lower() == name:lower() and conn_group:lower() == group:lower() then
      return nil, 'A connection with that name already exists in that group. Please choose a different group.'
    end
  end
  local out = vim.deepcopy(list)
  if match_idx ~= nil then
    if group == '' then
      out[match_idx].group = nil
    else
      out[match_idx].group = group
    end
  end
  return out, nil
end

---@private
--- Reorder the connection matching (name, url) one slot up or down among its
--- GROUP SIBLINGS -- the connections sharing its group (`''`/ungrouped is its
--- own sibling set). The drawer collates a group's members under one header
--- regardless of their raw array positions, so "up"/"down" is defined in that
--- visual sibling order, not raw array adjacency: it swaps the connection with
--- the nearest *earlier* (`up`) or *later* (`down`) connection sharing its group,
--- skipping over members of other groups in between. A no-op -- the list returned
--- The VISUAL (block) order of `list`, mirroring how the drawer renders it:
--- ungrouped connections appear in place, and each group's members are gathered
--- contiguously at the group's first-seen position. This is the order `<C-Up>` /
--- `<C-Down>` walk. Returns references into `list` (not copies).
---@param list DadbodUI.FileConnection[]
---@return DadbodUI.FileConnection[]
local function visual_order(list)
  local vis, seen = {}, {}
  for _, conn in ipairs(list) do
    local group = (conn.group or '')
    local gl = group:lower()
    if group == '' then
      vis[#vis + 1] = conn
    elseif not seen[gl] then
      seen[gl] = true
      for _, member in ipairs(list) do
        if (member.group or '') ~= '' and (member.group or ''):lower() == gl then
          vis[#vis + 1] = member
        end
      end
    end
  end
  return vis
end

--- Move the connection matching (name, url) one slot up/down in the drawer's
--- VISUAL order (see `visual_order`), crossing group boundaries. Within a group
--- (or ungrouped run) it is a plain reorder swap. At a block edge the connection
--- adopts the neighbouring block's group -- moving into the next group, out of a
--- group into ungrouped space, or into an ungrouped connection's group -- which is
--- what lets `<C-Up>`/`<C-Down>` drive the entire move (replacing the old
--- cut/paste flow). Clamped at the very top (`up`) / bottom (`down`) and a no-op
--- when nothing matches. Crossing into a group that already holds a *different*
--- connection of the same name is refused with `(nil, err)` (the `same_slot`
--- rule, which would otherwise collide two entries under one `key_name`).
--- Returns the list in normalized (block-contiguous) visual order, so groups stay
--- gathered. `(new_list, nil)` on success.
---@param list DadbodUI.FileConnection[]
---@param name string
---@param url string
---@param direction 'up'|'down'
---@return DadbodUI.FileConnection[]|nil, string|nil
function M.move_connection(list, name, url, direction)
  local resolved = bridge.resolve(url):lower()
  -- Deepcopy up front and drive everything off the copy's visual order, so the
  -- returned list is a fresh, block-contiguous ordering and the input is untouched.
  local out = visual_order(vim.deepcopy(list))
  local i = nil
  for idx, conn in ipairs(out) do
    if same_conn(conn, name, resolved) then
      i = idx
      break
    end
  end
  if i == nil then
    return out, nil
  end
  local j = direction == 'up' and i - 1 or i + 1
  if j < 1 or j > #out then
    return out, nil -- clamped at the very top / bottom
  end

  local moving = out[i]
  local neighbor = out[j]
  if (moving.group or ''):lower() == (neighbor.group or ''):lower() then
    -- Same block: a plain reorder among siblings.
    out[i], out[j] = out[j], out[i]
    return out, nil
  end

  -- Block boundary: `moving` crosses into the neighbour's block, adopting its
  -- group. In visual order `moving` already sits immediately adjacent to the
  -- neighbour on the correct side (after it when moving up, before it when moving
  -- down), so only the group changes -- no reorder. Refuse a name collision in
  -- the target group first (mirrors add/set_group).
  local target_group = neighbor.group or ''
  for k, conn in ipairs(out) do
    if k ~= i and same_slot(conn, name, target_group) then
      return nil, 'A connection with that name already exists in that group. Please choose a different group.'
    end
  end
  -- (An explicit if/else, not `cond and nil or x`: that idiom can't yield nil.)
  if target_group == '' then
    moving.group = nil
  else
    moving.group = target_group
  end
  return out, nil
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
