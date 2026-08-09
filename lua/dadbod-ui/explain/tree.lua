-- The explain-tree window (buffer, keymaps, collapse state)
--
-- The buffer-touching half of the explain tree: `render.rows` computes what to
-- show (pure), this module owns where it shows -- one scratch buffer in a
-- vertical split beside the query, repainted in full on every state change
-- (plans are small; the drawer's incremental diff would be over-engineering
-- here). Line N of the buffer is `rows[N]`, so every handler resolves the node
-- under the cursor with a single index -- the same line<->node contract the
-- drawer uses.
--
-- One tree at a time: opening a new plan reuses the window and replaces the
-- state. Collapse state is view-owned (row ids from the renderer), reset per
-- plan -- a re-explained query is a different tree and stale fold state would
-- attach to the wrong nodes.

---@private
local float = require('dadbod-ui.float')
---@private
local highlights = require('dadbod-ui.highlights')
---@private
local icons = require('dadbod-ui.icons')
---@private
local mappings = require('dadbod-ui.mappings')
---@private
local render = require('dadbod-ui.explain.render')
---@private
local state = require('dadbod-ui.state')

local M = {}

--- Extmark namespace for the tree's own row highlights (NOT shared with the
--- drawer's `dadbod_ui` namespace, whose paint cycle clears it).
M.NS = vim.api.nvim_create_namespace('dadbod_ui_explain_tree')

--- The open tree, or nil. One per session by design.
---@class DadbodUI.ExplainTree
---@field bufnr integer
---@field winid integer
---@field plan DadbodUI.ExplainPlan
---@field rows DadbodUI.ExplainRow[]
---@field collapsed table<string, boolean>
---@private
local current = nil

---@private
--- The float this module has open (help / node details), if any.
local float_winid = nil

---@private
local function close_float()
  if float_winid ~= nil and vim.api.nvim_win_is_valid(float_winid) then
    vim.api.nvim_win_close(float_winid, true)
  end
  float_winid = nil
end

---@private
--- Open the module's one informational float (the shared centered recipe).
---@param lines string[]
---@param title string
local function open_float(lines, title)
  close_float()
  float_winid = float.open(lines, {
    title = title,
    on_close = function()
      float_winid = nil
    end,
  })
end

---@private
--- Write `rows` into the tree buffer and lay their highlight ranges as
--- extmarks. Full repaint on purpose (see the module header).
---@param tree DadbodUI.ExplainTree
local function paint(tree)
  local lines = vim.tbl_map(function(row)
    return row.line
  end, tree.rows)
  local bo = vim.bo[tree.bufnr]
  bo.modifiable = true
  vim.api.nvim_buf_set_lines(tree.bufnr, 0, -1, false, lines)
  bo.modifiable = false
  vim.api.nvim_buf_clear_namespace(tree.bufnr, M.NS, 0, -1)
  for i, row in ipairs(tree.rows) do
    highlights.apply_line_highlights(tree.bufnr, i - 1, row.highlights, M.NS)
  end
end

---@private
--- Recompute rows from the plan + current collapse state and repaint,
--- keeping the cursor on the same node when possible.
---@param tree DadbodUI.ExplainTree
---@param keep_id? string  row id to keep the cursor on
local function refresh(tree, keep_id)
  local config = state.config()
  local cfg = config.explain or {}
  tree.rows = render.rows(tree.plan, {
    collapsed = tree.collapsed,
    heat = cfg.heat,
    skew_threshold = cfg.skew_threshold,
    collapsed_icon = icons.resolve(config).collapsed.explain,
  })
  paint(tree)
  if keep_id ~= nil and vim.api.nvim_win_is_valid(tree.winid) then
    for i, row in ipairs(tree.rows) do
      if row.id == keep_id then
        vim.api.nvim_win_set_cursor(tree.winid, { i, 0 })
        break
      end
    end
  end
end

--- The row under the cursor of the tree window (nil on the header/spacer or
--- when no tree is open).
---@return DadbodUI.ExplainRow|nil
function M.current_row()
  if current == nil or not vim.api.nvim_win_is_valid(current.winid) then
    return nil
  end
  return current.rows[vim.api.nvim_win_get_cursor(current.winid)[1]]
end

--- Collapse/expand the subtree under the cursor (no-op on leaves).
---@return nil
function M.toggle_node()
  local row = M.current_row()
  if current == nil or row == nil or row.node == nil or #row.node.children == 0 then
    return
  end
  current.collapsed[row.id] = not current.collapsed[row.id] or nil
  refresh(current, row.id)
end

---@private
--- Flatten one raw plan-node value for the detail float.
---@param value any
---@return string
local function detail_value(value)
  if type(value) == 'table' then
    return table.concat(
      vim.tbl_map(function(v)
        return tostring(v)
      end, value),
      ', '
    )
  end
  return tostring(value)
end

--- Show the full adapter-reported detail of the node under the cursor in a
--- float: every raw key the row didn't have space for (buffers, I/O timings,
--- workers), sorted, children omitted.
---@return nil
function M.node_details()
  local row = M.current_row()
  if row == nil or row.node == nil then
    return
  end
  local keys = vim.tbl_keys(row.node.raw)
  table.sort(keys)
  open_float(
    vim.tbl_map(function(key)
      return string.format('%s: %s', key, detail_value(row.node.raw[key]))
    end, keys),
    row.node.op
  )
end

--- Show the keymap help float (all contexts, same recipe as the drawer's).
---@return nil
function M.help()
  open_float(mappings.help_lines(state.config()), 'Help')
end

--- Close the tree window and drop its state.
---@return nil
function M.close()
  close_float()
  if current ~= nil and vim.api.nvim_win_is_valid(current.winid) then
    vim.api.nvim_win_close(current.winid, true)
  end
  current = nil
end

---@private
--- Create (or reuse) the tree window + scratch buffer.
---@return integer bufnr, integer winid
local function ensure_window()
  if current ~= nil and vim.api.nvim_win_is_valid(current.winid) then
    return current.bufnr, current.winid
  end
  local cfg = state.config().explain or {}
  -- `position` picks the orientation: top/bottom split horizontally (height),
  -- left/right split vertically (width).
  local horizontal = cfg.position == 'top' or cfg.position == 'bottom'
  if horizontal then
    local mods = cfg.position == 'top' and 'topleft' or 'botright'
    vim.cmd(string.format('%s %dnew', mods, cfg.height or 15))
  else
    local mods = cfg.position == 'left' and 'topleft' or 'botright'
    vim.cmd(string.format('%s vertical %dnew', mods, cfg.width or 72))
  end
  local winid = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_get_current_buf()
  local bo = vim.bo[bufnr]
  bo.buftype = 'nofile'
  bo.bufhidden = 'wipe'
  bo.swapfile = false
  bo.buflisted = false
  bo.filetype = 'dbui-explain'
  local wo = vim.wo[winid]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = 'no'
  wo.winfixwidth = not horizontal
  wo.winfixheight = horizontal
  wo.wrap = false

  local handlers = {
    toggle_node = M.toggle_node,
    node_details = M.node_details,
    close = M.close,
    help = M.help,
  }
  local function make_ctx(mode)
    local row = M.current_row()
    return { mode = mode, bufnr = bufnr, node = row and row.node or nil }
  end
  local config = state.config()
  mappings.apply(config.explain.keys, handlers, config.actions, make_ctx, {
    buffer = bufnr,
    silent = true,
    nowait = true,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    once = true,
    callback = function()
      current = nil
    end,
  })
  return bufnr, winid
end

--- Open (or replace) the explain tree for `plan`.
---@param plan DadbodUI.ExplainPlan
---@return nil
function M.open(plan)
  local bufnr, winid = ensure_window()
  current = {
    bufnr = bufnr,
    winid = winid,
    plan = plan,
    rows = {},
    collapsed = {},
  }
  refresh(current)
  vim.api.nvim_win_set_cursor(winid, { math.min(3, vim.api.nvim_buf_line_count(bufnr)), 0 })
end

--- The open tree state (nil when closed). Exposed for tests.
---@return DadbodUI.ExplainTree|nil
function M.get()
  if current ~= nil and not vim.api.nvim_win_is_valid(current.winid) then
    current = nil
  end
  return current
end

return M
