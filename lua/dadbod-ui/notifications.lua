-- User-facing messages
--
-- The plugin's notification layer over `vim.notify`. Messages route
-- through `vim.notify` (so a UI plugin like nvim-notify can render them), with
-- an `:echo` fallback for users who prefer the command line.
--
-- Honors the resolved config (read lazily from `dadbod-ui.state`):
-- `disable_info_notifications` suppresses info, `force_echo_notifications`
-- forces the echo backend, `use_nvim_notify` opts into nvim-notify niceties
-- (info-toast replacement). The title is always `constants.notify_title`.

---@class DadbodUI.NotificationsModule
---@field info fun(msg: string|string[], opts?: DadbodUI.NotifyOpts)
---@field warn fun(msg: string|string[], opts?: DadbodUI.NotifyOpts)
---@field error fun(msg: string|string[], opts?: DadbodUI.NotifyOpts)
---@field confirm fun(msg: string): boolean
---@field get_last_msg fun(): string

---@type DadbodUI.NotificationsModule
---@diagnostic disable-next-line: missing-fields
local M = {}

---@private
local TITLE = require('dadbod-ui.constants').notify_title

---@private
---@type table<DadbodUI.NotifyKind, integer>
local LEVELS = {
  info = vim.log.levels.INFO,
  warning = vim.log.levels.WARN,
  error = vim.log.levels.ERROR,
}

---@private
---@type table<DadbodUI.NotifyKind, string>
local ECHO_HL = {
  info = 'None',
  warning = 'WarningMsg',
  error = 'ErrorMsg',
}

---@private
-- Last message shown, exposed via get_last_msg() for the statusline/tests.
local last_msg = ''

---@private
-- True when msg carries no content.
---@param msg string|string[]
---@return boolean
local function is_empty(msg)
  if msg == nil or msg == '' then
    return true
  end
  return type(msg) == 'table' and vim.tbl_isempty(msg)
end

---@private
-- Flatten a string or string-list into a single newline-joined message.
---@param msg string|string[]
---@return string
local function to_text(msg)
  if type(msg) == 'table' then
    return table.concat(msg, '\n')
  end
  return tostring(msg)
end

---@private
-- Build the opts table handed to vim.notify. nvim-notify reads `title` and,
-- for info, an `id` so repeated info toasts replace one another.
---@param kind DadbodUI.NotifyKind
---@param config DadbodUI.Config
---@param opts DadbodUI.NotifyOpts
---@return table
local function build_opts(kind, config, opts)
  local out = { title = opts.title or TITLE }
  if opts.delay then
    out.timeout = opts.delay
  end
  if config.notifications.use_nvim_notify and kind == 'info' then
    out.id = 'dadbod-ui-info'
  end
  return out
end

---@private
-- Core dispatch: suppress disabled info, then route to echo or vim.notify.
---@param msg string|string[]
---@param kind DadbodUI.NotifyKind
---@param opts? DadbodUI.NotifyOpts
local function emit(msg, kind, opts)
  if is_empty(msg) then
    return
  end
  opts = opts or {}
  local config = require('dadbod-ui.state').config()
  if kind == 'info' and config.notifications.disable_info then
    return
  end

  local text = to_text(msg)
  last_msg = text

  if opts.echo or config.notifications.force_echo then
    vim.api.nvim_echo({ { (opts.title or TITLE) .. ' ' .. text, ECHO_HL[kind] } }, true, {})
    return
  end

  vim.notify(text, LEVELS[kind], build_opts(kind, config, opts))
end

--- Show an info message (suppressed when `disable_info_notifications`).
---@param msg string|string[]
---@param opts? DadbodUI.NotifyOpts
function M.info(msg, opts)
  emit(msg, 'info', opts)
end

--- Show a warning message.
---@param msg string|string[]
---@param opts? DadbodUI.NotifyOpts
function M.warn(msg, opts)
  emit(msg, 'warning', opts)
end

--- Show an error message.
---@param msg string|string[]
---@param opts? DadbodUI.NotifyOpts
function M.error(msg, opts)
  emit(msg, 'error', opts)
end

--- Ask the user a yes/no question. Returns true only when they pick Yes.
---@param msg string
---@return boolean
function M.confirm(msg)
  return vim.fn.confirm(msg, '&Yes\n&No') == 1
end

--- The last message shown (newline-joined). Empty string before any message.
---@return string
function M.get_last_msg()
  return last_msg
end

return M
