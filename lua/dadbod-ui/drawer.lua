---@mod dadbod-ui.drawer  The tree UI (window + content render + interaction)
---
--- Mirrors the original: a scratch buffer whose lines are built from a
--- `content[]` array where line N maps to a node. The cursor line indexes
--- `content` to find the node and its action. Highlighting/ftplugin and the
--- richer sections (tables, schemas, buffers) land in later slices.

local icons_mod = require('dadbod-ui.icons')

local INDENT = 2

local M = {}

---@class DadbodUI.Drawer
---@field instance DadbodUI.Instance
---@field icons table
---@field config table
---@field content table[]  line N -> node
---@field groups table<string, { expanded: boolean }>
---@field bufnr integer|nil
---@field winid integer|nil
local Drawer = {}
Drawer.__index = Drawer

--- Create a drawer over `instance` (defaults to the session singleton).
---@param instance DadbodUI.Instance|nil
---@return DadbodUI.Drawer
function M.new(instance)
  instance = instance or require('dadbod-ui.state').get()
  return setmetatable({
    instance = instance,
    icons = icons_mod.resolve(instance.config),
    config = instance.config,
    content = {},
    groups = {},
    bufnr = nil,
    winid = nil,
  }, Drawer)
end

function Drawer:group_state(name)
  if self.groups[name] == nil then
    self.groups[name] = { expanded = self.config.expand_groups and true or false }
  end
  return self.groups[name]
end

function Drawer:is_open()
  return self.winid ~= nil and vim.api.nvim_win_is_valid(self.winid)
end

--- Open the drawer window, or focus it if already open.
---@param mods string|nil  command modifiers (e.g. 'tab')
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

function Drawer:close()
  if self:is_open() then
    vim.api.nvim_win_close(self.winid, true)
  end
  self.winid = nil
  self.bufnr = nil
end

Drawer.quit = Drawer.close

function Drawer:toggle()
  if self:is_open() then
    self:close()
  else
    self:open()
  end
end

function Drawer:add(node)
  self.content[#self.content + 1] = node
end

function Drawer:toggle_icon(kind, expanded)
  return expanded and self.icons.expanded[kind] or self.icons.collapsed[kind]
end

--- Rebuild `content` from the instance and write the buffer lines.
function Drawer:render()
  if not self:is_open() then
    return self
  end
  self.content = {}
  self:render_dbs()

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

function Drawer:render_db(record, level)
  local entry = self.instance.dbs[record.key_name]
  self:add({
    label = record.name,
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

function Drawer:current_line()
  return vim.api.nvim_win_get_cursor(self.winid)[1]
end

function Drawer:set_cursor(line)
  line = math.max(1, math.min(line, #self.content))
  local col = vim.api.nvim_win_get_cursor(self.winid)[2]
  vim.api.nvim_win_set_cursor(self.winid, { line, col })
end

--- The node under the cursor (or nil).
---@return table|nil
function Drawer:get_current_item()
  if not self:is_open() then
    return nil
  end
  return self.content[self:current_line()]
end

--- Act on the node under the cursor: toggle groups/dbs (open actions for
--- queries/buffers are handled once the query module lands).
function Drawer:toggle_line()
  local item = self:get_current_item()
  if item == nil or item.action == 'noaction' then
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

--- Move to a sibling at the same tree level. `direction` is
--- 'first' | 'last' | 'next' | 'prev'. Stops at level boundaries and at the
--- top-level separators (level 0 with an empty label).
---@param direction string
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

function Drawer:setup_mappings()
  if self.config.disable_mappings or self.config.disable_mappings_dbui then
    return
  end
  local function map(lhs, fn)
    vim.keymap.set('n', lhs, function()
      fn()
    end, { buffer = self.bufnr, nowait = true, silent = true })
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
