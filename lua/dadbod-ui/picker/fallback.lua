-- Connection picker: vim.ui.select fallback
--
-- Used when no picker plugin is installed (or `config.picker = 'fallback'`).
-- Built into Neovim, so it is always available.

---@type DadbodUI.PickerBackend
---@diagnostic disable-next-line: missing-fields
local M = {}

--- Show the picker via vim.ui.select. `_opts` is unused (vim.ui.select takes
--- no passthrough config); accepted for backend-interface compliance.
---@param items DadbodUI.PickerItem[]
---@param _opts? table
---@param on_select DadbodUI.PickerSelect
---@return boolean
function M.show(items, _opts, on_select)
  vim.ui.select(items, {
    prompt = 'Connections',
    format_item = function(item)
      return item.text
    end,
  }, on_select)
  return true
end

return M
