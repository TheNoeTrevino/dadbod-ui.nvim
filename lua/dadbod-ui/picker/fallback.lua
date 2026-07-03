-- Connection picker: vim.ui.select fallback
--
-- Used when no picker plugin is installed (or `config.picker = 'fallback'`).
-- Built into Neovim, so it is always available.

local utils = require('dadbod-ui.picker.utils')

---@type DadbodUI.PickerBackend
---@diagnostic disable-next-line: missing-fields
local M = {}

--- Always true: vim.ui.select is built in.
---@return boolean
function M.is_available()
  return true
end

--- Show the picker via vim.ui.select. `_opts` is unused (vim.ui.select takes
--- no passthrough config); accepted for backend-interface compliance.
---@param _opts? table
---@return boolean
function M.show(_opts)
  vim.ui.select(utils.build_items(), {
    prompt = 'Connections',
    format_item = function(item)
      return item.text
    end,
  }, function(choice)
    utils.connect(choice)
  end)
  return true
end

return M
