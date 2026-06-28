---@mod dadbod-ui.drawer  The tree UI (window + content render + interaction)
---
--- Mirrors the original: a scratch buffer whose lines are built from a
--- `content[]` array where line N maps to a node. The cursor line indexes
--- `content` to find the node and its action. Highlighting/ftplugin and the
--- richer sections (tables, schemas, buffers) land in later slices.

local icons_mod = require('dadbod-ui.icons')
local connections = require('dadbod-ui.connections')
local bridge = require('dadbod-ui.bridge')

local INDENT = 2

local HELP_LINES = {
  '" o - Open/Toggle selected item',
  '" S - Open/Toggle selected item in vertical split',
  '" d - Delete selected item',
  '" R - Redraw',
  '" A - Add connection',
  '" G - Add/remove connection to a group',
  '" H - Toggle database details',
  '" r - Rename/Edit buffer/connection/saved query',
  '" q - Close drawer',
  '" <C-j>/<C-k> - Go to last/first sibling',
  '" K/J - Go to prev/next sibling',
  '" <C-p>/<C-n> - Go to parent/child node',
}

local M = {}

---@class DadbodUI.Drawer
---@field instance DadbodUI.Instance
---@field icons DadbodUI.Icons
---@field config DadbodUI.Config
---@field content DadbodUI.Node[]  line N -> node
---@field groups table<string, { expanded: boolean }>
---@field show_help boolean
---@field show_details boolean
---@field input DadbodUI.UiInput  prompt backend (injectable for specs)
---@field confirm DadbodUI.Confirm  yes/no backend (injectable for specs)
---@field bufnr? integer
---@field winid? integer
local Drawer = {}
Drawer.__index = Drawer

--- Create a drawer over `instance` (defaults to the session singleton).
---@param instance? DadbodUI.Instance
---@return DadbodUI.Drawer
function M.new(instance)
  instance = instance or require('dadbod-ui.state').get()
  return setmetatable({
    instance = instance,
    icons = icons_mod.resolve(instance.config),
    config = instance.config,
    content = {},
    groups = {},
    show_help = false,
    show_details = false,
    input = vim.ui.input,
    confirm = function(msg)
      return require('dadbod-ui.notifications').confirm(msg)
    end,
    bufnr = nil,
    winid = nil,
  }, Drawer)
end

---@param name string
---@return { expanded: boolean }
function Drawer:group_state(name)
  if self.groups[name] == nil then
    self.groups[name] = { expanded = self.config.expand_groups }
  end
  return self.groups[name]
end

---@return boolean
function Drawer:is_open()
  return self.winid ~= nil and vim.api.nvim_win_is_valid(self.winid)
end

--- Open the drawer window, or focus it if already open.
---@param mods? string  command modifiers (e.g. 'tab')
---@return DadbodUI.Drawer
function Drawer:open(mods)
  if self:is_open() then
    vim.api.nvim_set_current_win(self.winid)
    return self
  end
  local side = self.config.win_position == 'right' and 'botright' or 'topleft'
  vim.cmd(string.format('silent! %s vertical %s %dnew', mods or '', side, self.config.winwidth))
  self.winid = vim.api.nvim_get_current_win()
  self.bufnr = vim.api.nvim_get_current_buf()

  local bo = vim.bo[self.bufnr]
  bo.buftype = 'nofile'
  bo.bufhidden = 'wipe'
  bo.buflisted = false
  bo.swapfile = false
  local wo = vim.wo[self.winid]
  wo.wrap = false
  wo.number = false
  wo.relativenumber = false
  wo.spell = false
  wo.list = false
  wo.signcolumn = 'no'
  wo.winfixwidth = true

  self:setup_mappings()
  vim.api.nvim_create_autocmd('BufEnter', {
    buffer = self.bufnr,
    callback = function()
      self:render()
    end,
  })
  self:render()
  bo.filetype = 'dbui'
  return self
end

---@return nil
function Drawer:close()
  if self:is_open() then
    vim.api.nvim_win_close(self.winid, true)
  end
  self.winid = nil
  self.bufnr = nil
end

Drawer.quit = Drawer.close

---@return nil
function Drawer:toggle()
  if self:is_open() then
    self:close()
  else
    self:open()
  end
end

---@param node DadbodUI.Node
function Drawer:add(node)
  self.content[#self.content + 1] = node
end

---@param kind string
---@param expanded boolean
---@return string
function Drawer:toggle_icon(kind, expanded)
  return expanded and self.icons.expanded[kind] or self.icons.collapsed[kind]
end

--- Rebuild `content` from the instance and write the buffer lines.
---@return DadbodUI.Drawer
function Drawer:render()
  if not self:is_open() then
    return self
  end
  self.content = {}
  self:render_help()
  self:render_dbs()
  if #self.instance.dbs_list == 0 then
    self:add({ label = '" No connections', icon = '', level = 0, type = 'help', action = 'noaction' })
    self:add({ label = 'Add connection', icon = self.icons.add_connection, level = 0, type = 'add_connection', action = 'call_method' })
  end

  local lines = {}
  for _, node in ipairs(self.content) do
    local indent = string.rep(' ', INDENT * node.level)
    local sep = node.icon ~= '' and ' ' or ''
    lines[#lines + 1] = indent .. node.icon .. sep .. node.label
  end

  local bo = vim.bo[self.bufnr]
  bo.modifiable = true
  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
  bo.modifiable = false
  return self
end

---@return nil
function Drawer:render_help()
  if self.config.show_help then
    self:add({ label = '" Press ? for help', icon = '', level = 0, type = 'help', action = 'noaction' })
    self:add({ label = '', icon = '', level = 0, type = 'help', action = 'noaction' })
  end
  if self.show_help then
    for _, line in ipairs(HELP_LINES) do
      self:add({ label = line, icon = '', level = 0, type = 'help', action = 'noaction' })
    end
    self:add({ label = '', icon = '', level = 0, type = 'help', action = 'noaction' })
  end
end

---@return DadbodUI.Drawer
function Drawer:toggle_help()
  self.show_help = not self.show_help
  return self:render()
end

---@return DadbodUI.Drawer
function Drawer:toggle_details()
  self.show_details = not self.show_details
  return self:render()
end

---@return nil
function Drawer:render_dbs()
  local last_group = nil
  for _, record in ipairs(self.instance.dbs_list) do
    local group = record.group or ''
    if group == '' then
      last_group = nil
      self:render_db(record, 0)
    else
      if group ~= last_group then
        local gs = self:group_state(group)
        self:add({
          label = group,
          icon = self:toggle_icon('group', gs.expanded),
          level = 0,
          type = 'group',
          action = 'toggle',
          group = group,
          expanded = gs.expanded,
        })
        last_group = group
      end
      if self:group_state(group).expanded then
        self:render_db(record, 1)
      end
    end
  end
end

---@param record DadbodUI.ConnectionRecord
---@param level integer
function Drawer:render_db(record, level)
  local entry = self.instance.dbs[record.key_name]
  local label = record.name
  if entry.conn_error and entry.conn_error ~= '' then
    label = label .. ' ' .. self.icons.connection_error
  elseif entry.conn and entry.conn ~= '' then
    label = label .. ' ' .. self.icons.connection_ok
  end
  if self.show_details then
    if entry.group ~= '' then
      label = label .. string.format(' (%s - %s - %s %s)', entry.scheme, entry.source, self.icons.group, entry.group)
    else
      label = label .. string.format(' (%s - %s)', entry.scheme, entry.source)
    end
  end
  self:add({
    label = label,
    icon = self:toggle_icon('db', entry.expanded),
    level = level,
    type = 'db',
    action = 'toggle',
    key_name = record.key_name,
    expanded = entry.expanded,
  })
  if entry.expanded then
    self:render_db_sections(entry, level + 1)
  end
end

---@param entry DadbodUI.ConnectionEntry
---@param level integer
function Drawer:render_db_sections(entry, level)
  for _, section in ipairs(self.config.drawer_sections) do
    if section == 'new_query' then
      self:add({
        label = 'New query',
        icon = self.icons.new_query,
        level = level,
        type = 'query',
        action = 'open',
        key_name = entry.key_name,
      })
    end
    -- buffers / saved_queries / schemas render once their data lands (later slices)
  end
end

---@return integer
function Drawer:current_line()
  return vim.api.nvim_win_get_cursor(self.winid)[1]
end

---@param line integer
function Drawer:set_cursor(line)
  line = math.max(1, math.min(line, #self.content))
  local col = vim.api.nvim_win_get_cursor(self.winid)[2]
  vim.api.nvim_win_set_cursor(self.winid, { line, col })
end

--- The node under the cursor (or nil).
---@return DadbodUI.Node|nil
function Drawer:get_current_item()
  if not self:is_open() then
    return nil
  end
  return self.content[self:current_line()]
end

--- Act on the node under the cursor: toggle groups/dbs (open actions for
--- queries/buffers are handled once the query module lands).
---@return DadbodUI.Drawer|nil
function Drawer:toggle_line()
  local item = self:get_current_item()
  if item == nil or item.action == 'noaction' then
    return
  end
  if item.action == 'call_method' then
    if item.type == 'add_connection' then
      self:add_connection()
    end
    return
  end
  if item.type == 'group' then
    self:group_state(item.group).expanded = not self:group_state(item.group).expanded
    return self:render()
  end
  if item.type == 'db' then
    local entry = self.instance.dbs[item.key_name]
    entry.expanded = not entry.expanded
    return self:render()
  end
end

-- Interactive connection management ------------------------------------------
--
-- These wire the drawer keys (A/d/r/R) to the pure CRUD transforms in
-- connections.lua. Prompts go through `self.input` (vim.ui.input by default),
-- so each flow is callback-based; all user-facing messages route through the
-- notifications layer. On success we write connections.json, re-discover, and
-- re-render.

--- Resolve and validate a url the user typed. Returns `(resolved, nil)` or
--- `(nil, err)` when dadbod rejects it.
---@param url string
---@return string|nil, string|nil
local function validate_url(url)
  local ok, result = pcall(function()
    local resolved = bridge.resolve(url)
    bridge.parse_url(resolved)
    return resolved
  end)
  if not ok then
    return nil, tostring(result)
  end
  return result, nil
end

--- Read the connections.json store, refusing to proceed when it is present but
--- corrupt -- so a CRUD action can't silently overwrite a file we failed to
--- parse. Returns the list, or nil when the store is unreadable.
---@return DadbodUI.FileConnection[]|nil
function Drawer:read_store()
  local corrupt = false
  local list = connections.read_file(self.instance.connections_path, function()
    corrupt = true
  end)
  if corrupt then
    require('dadbod-ui.notifications').error(
      'Could not read connections file; refusing to overwrite it. Fix or remove: ' .. (self.instance.connections_path or '')
    )
    return nil
  end
  return list
end

--- Persist `connections.json`, re-discover, and re-render.
---@param list DadbodUI.FileConnection[]
---@return nil
function Drawer:commit_connections(list)
  local path = self.instance.connections_path
  if path == nil then
    return
  end
  connections.write_file(path, list)
  self.instance:repopulate()
  self:render()
end

--- Add a new file-source connection (also `:DBUIAddConnection`). Prompts for a
--- url then a name; rejects an invalid url, a blank name, or a duplicate name.
---@return nil
function Drawer:add_connection()
  local notify = require('dadbod-ui.notifications')
  if self.instance.connections_path == nil then
    return notify.error('Please set up valid save location via g:db_ui_save_location')
  end
  self.input({ prompt = 'Enter connection url: ' }, function(url)
    if url == nil then
      return
    end
    local resolved, err = validate_url(url)
    if resolved == nil then
      return notify.error(err or 'Invalid connection url.')
    end
    self.input({ prompt = 'Enter name: ', default = resolved:match('[^/]*$') }, function(name)
      if name == nil then
        return
      end
      name = vim.trim(name)
      if name == '' then
        return notify.error('Please enter valid name.')
      end
      local store = self:read_store()
      if store == nil then
        return
      end
      local list, add_err = connections.add_connection(store, name, resolved)
      if list == nil then
        return notify.error(add_err or 'Could not add connection.')
      end
      self:commit_connections(list)
      notify.info('Saved connection.')
    end)
  end)
end

--- Rename/edit a connection. Only file-source connections are editable; others
--- are refused with a notification. Prompts for a new url then a new name.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Drawer:rename_connection(entry)
  local notify = require('dadbod-ui.notifications')
  if entry.source ~= 'file' then
    return notify.error('Cannot edit connections added via variables.')
  end
  self.input({ prompt = string.format('Edit connection url for "%s": ', entry.name), default = entry.url }, function(url)
    if url == nil then
      return
    end
    local resolved, err = validate_url(url)
    if resolved == nil then
      return notify.error(err or 'Invalid connection url.')
    end
    self.input({ prompt = 'Edit connection name: ', default = entry.name }, function(name)
      if name == nil then
        return
      end
      name = vim.trim(name)
      if name == '' then
        return notify.error('Please enter valid name.')
      end
      local store = self:read_store()
      if store == nil then
        return
      end
      local list, rename_err = connections.rename_connection(store, entry.name, entry.url, name, resolved)
      if list == nil then
        return notify.error(rename_err or 'Could not rename connection.')
      end
      self:commit_connections(list)
    end)
  end)
end

--- Assign a connection to a group (or clear it). A group is just a shared name:
--- entering an existing group joins it, a new name creates it, and an empty
--- entry ungroups. Only file-source connections are editable.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Drawer:set_group(entry)
  local notify = require('dadbod-ui.notifications')
  if entry.source ~= 'file' then
    return notify.error('Cannot edit connections added via variables.')
  end
  self.input({ prompt = 'Enter group name: ', default = entry.group }, function(group)
    if group == nil then
      return
    end
    group = vim.trim(group)
    local store = self:read_store()
    if store == nil then
      return
    end
    local list, err = connections.set_group(store, entry.name, entry.url, group)
    if list == nil then
      return notify.error(err or 'Could not set group.')
    end
    self:commit_connections(list)
  end)
end

--- Group the connection under the cursor (`G`).
---@return nil
function Drawer:set_group_line()
  local item = self:get_current_item()
  if item == nil then
    return
  end
  if item.type == 'db' then
    return self:set_group(self.instance.dbs[item.key_name])
  end
end

--- Delete the connection under the cursor (`d`). Only file-source connections
--- can be deleted; others are refused. Asks for confirmation first.
---@return nil
function Drawer:delete_line()
  local item = self:get_current_item()
  if item == nil or item.action == 'noaction' then
    return
  end
  if item.action == 'toggle' and item.type == 'db' then
    local entry = self.instance.dbs[item.key_name]
    if entry.source ~= 'file' then
      return require('dadbod-ui.notifications').error('Cannot delete this connection.')
    end
    return self:delete_connection(entry)
  end
  -- buffer / saved-query deletion lands with the query milestone
end

--- Confirm, then remove a file-source connection.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Drawer:delete_connection(entry)
  if not self.confirm(string.format('Are you sure you want to delete connection %s?', entry.name)) then
    return
  end
  local store = self:read_store()
  if store == nil then
    return
  end
  local list = connections.delete_connection(store, entry.name, entry.url)
  self:commit_connections(list)
end

--- Rename the node under the cursor (`r`). Connections route to
--- `rename_connection`; buffers/saved queries land in a later milestone.
---@return nil
function Drawer:rename_line()
  local item = self:get_current_item()
  if item == nil then
    return
  end
  if item.type == 'db' then
    return self:rename_connection(self.instance.dbs[item.key_name])
  end
end

--- Refresh the tree (`R`): re-discover connections from disk and re-render.
--- A finer-grained per-database refresh arrives with schema introspection.
---@return nil
function Drawer:redraw()
  local item = self:get_current_item()
  if item == nil then
    return
  end
  local notify = require('dadbod-ui.notifications')
  if item.type == 'db' and item.key_name ~= nil then
    local entry = self.instance.dbs[item.key_name]
    notify.info(string.format('Refreshing database %s...', entry and entry.name or ''))
  else
    notify.info('Refreshing all databases...')
  end
  self.instance:repopulate()
  self:render()
end

--- Move to a sibling at the same tree level. `direction` is
--- 'first' | 'last' | 'next' | 'prev'. Stops at level boundaries and at the
--- top-level separators (level 0 with an empty label).
---@param direction string  'first' | 'last' | 'next' | 'prev'
---@return nil
function Drawer:goto_sibling(direction)
  local line = self:current_line()
  local n = #self.content
  local item = self.content[line]
  if item == nil then
    return
  end
  local level = item.level
  local is_up = direction == 'first' or direction == 'prev'
  local is_down = not is_up
  local is_edge = direction == 'first' or direction == 'last'
  local is_prev_or_next = not is_edge
  local last_same = line

  local idx = line
  while (is_up and idx >= 1) or (is_down and idx <= n) do
    local adj = is_up and idx - 1 or idx + 1
    if adj < 1 or adj > n then
      return
    end
    local adjacent = self.content[adj]
    local on_edge = (is_up and adj == 1) or (is_down and adj == n)
    if adjacent.level == 0 and adjacent.label == '' then
      return self:set_cursor(idx)
    end
    if is_prev_or_next then
      if adjacent.level == level then
        return self:set_cursor(adj)
      end
      if adjacent.level < level then
        return
      end
    end
    if is_edge then
      if adjacent.level == level then
        last_same = adj
      end
      if adjacent.level < level or on_edge then
        return self:set_cursor(last_same)
      end
    end
    idx = adj
  end
end

--- Move to the parent node (level - 1) or the first child (level + 1).
--- A collapsed node is expanded first when descending.
---@param direction string  'parent' | 'child'
---@return nil
function Drawer:goto_node(direction)
  local line = self:current_line()
  local item = self.content[line]
  if item == nil then
    return
  end
  if direction == 'parent' then
    local idx = line
    while idx >= 1 do
      idx = idx - 1
      local adjacent = self.content[idx]
      if adjacent == nil or adjacent.level < item.level then
        break
      end
    end
    return self:set_cursor(idx)
  end
  if item.action ~= 'toggle' then
    return
  end
  if not item.expanded then
    self:toggle_line()
  end
  self:set_cursor(line + 1)
end

---@return nil
function Drawer:setup_mappings()
  ---@param lhs string
  ---@param fn fun()
  local function map(lhs, fn)
    vim.keymap.set('n', lhs, fn, { buffer = self.bufnr, nowait = true, silent = true })
  end
  -- help toggle is always available, matching the original
  map('?', function()
    self:toggle_help()
  end)
  if self.config.disable_mappings or self.config.disable_mappings_dbui then
    return
  end
  map('o', function()
    self:toggle_line()
  end)
  map('<CR>', function()
    self:toggle_line()
  end)
  map('q', function()
    self:quit()
  end)
  map('A', function()
    self:add_connection()
  end)
  map('d', function()
    self:delete_line()
  end)
  map('r', function()
    self:rename_line()
  end)
  map('R', function()
    self:redraw()
  end)
  map('G', function()
    self:set_group_line()
  end)
  map('H', function()
    self:toggle_details()
  end)
  map('<C-k>', function()
    self:goto_sibling('first')
  end)
  map('<C-j>', function()
    self:goto_sibling('last')
  end)
  map('K', function()
    self:goto_sibling('prev')
  end)
  map('J', function()
    self:goto_sibling('next')
  end)
  map('<C-p>', function()
    self:goto_node('parent')
  end)
  map('<C-n>', function()
    self:goto_node('child')
  end)
end

M.Drawer = Drawer
return M
