-- Connection picker
--
-- An interactive list of every discovered connection; `<CR>` connects the
-- selection. Routes to a picker backend by `config.picker`:
--   * 'auto' (default): try Snacks.nvim, Telescope.nvim, fzf-lua, then fall
--     back to vim.ui.select
--   * 'snacks' | 'telescope' | 'fzf': that plugin only (warns when missing)
--   * 'fallback': vim.ui.select
-- One file per backend; `utils.lua` holds the shared item building + select
-- action. Reached through `require('dadbod-ui.api').pick()`.

---@class DadbodUI.PickerRouter
---@field show fun(opts?: table)

local notifications = require('dadbod-ui.notifications')

---@type DadbodUI.PickerRouter
---@diagnostic disable-next-line: missing-fields
local M = {}

---@private
---@param name string  backend module name ('snacks'|'telescope'|'fzf'|'fallback')
---@return DadbodUI.PickerBackend
local function backend(name)
  return require('dadbod-ui.picker.' .. name)
end

---@private
---@param opts? table
local function show_auto(opts)
  for _, name in ipairs({ 'snacks', 'telescope', 'fzf' }) do
    if backend(name).show(opts) then
      return
    end
  end
  backend('fallback').show(opts)
end

--- Open the connection picker. `opts` is passed straight to the underlying
--- picker implementation, so its shape depends on the configured backend
--- (e.g. a `snacks.picker.Config` for snacks).
---@param opts? table
function M.show(opts)
  if #require('dadbod-ui.picker.utils').build_items() == 0 then
    return notifications.info('No connections found')
  end

  local picker_type = require('dadbod-ui.state').config().picker or 'auto'
  if picker_type == 'auto' then
    return show_auto(opts)
  end

  if not backend(picker_type).show(opts) then
    notifications.warn(string.format("picker '%s' is not available", picker_type))
  end
end

return M
