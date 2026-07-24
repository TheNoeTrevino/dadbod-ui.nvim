-- The centered floating window recipe
--
-- One implementation of the rounded, centered, minimal-style informational
-- float (help window, explain node details): scratch buffer, width from the
-- widest line, height clamped to the screen, close on the given keys and on
-- BufLeave. Extracted from the drawer's help float so every caller stays
-- pixel-identical and close-behavior changes happen once.

---@class DadbodUI.FloatOpts
---@field title string
---@field close_keys? string[]  normal-mode keys that close the float (default q / <Esc>)
---@field on_close? fun()  invoked exactly once, however the float closes

---@class DadbodUI.FloatModule
---@field open fun(lines: string[], opts: DadbodUI.FloatOpts): integer

---@type DadbodUI.FloatModule
---@diagnostic disable-next-line: missing-fields
local M = {}

--- Open a centered rounded float over `lines`, focused. Returns the window id.
---@param lines string[]
---@param opts DadbodUI.FloatOpts
---@return integer winid
function M.open(lines, opts)
  local max_len = vim.iter(lines):fold(0, function(acc, line)
    return math.max(acc, vim.fn.strdisplaywidth(line))
  end)
  local width = math.min(max_len + 4, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 6)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].bufhidden = 'wipe'

  local winid = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    border = 'rounded',
    title = ' ' .. opts.title .. ' ',
    title_pos = 'center',
    style = 'minimal',
  })

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end
    if opts.on_close ~= nil then
      opts.on_close()
    end
  end
  for _, key in ipairs(opts.close_keys or { 'q', '<Esc>' }) do
    vim.keymap.set('n', key, close, { buffer = buf, nowait = true, silent = true })
  end
  vim.api.nvim_create_autocmd('BufLeave', { buffer = buf, once = true, callback = close })
  return winid
end

return M
