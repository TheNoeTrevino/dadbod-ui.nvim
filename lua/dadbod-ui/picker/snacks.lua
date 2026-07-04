-- Connection picker: Snacks.nvim backend
--
-- Requires Snacks.nvim (https://github.com/folke/snacks.nvim).
-- `<CR>` connects the selected connection.

local utils = require('dadbod-ui.picker.utils')

---@type DadbodUI.PickerBackend
---@diagnostic disable-next-line: missing-fields
local M = {}

--- Whether Snacks.nvim is installed.
---@return boolean
function M.is_available()
  return (pcall(require, 'snacks'))
end

--- Show the Snacks picker.
---@param opts? table  snacks.picker.Config overrides
---@param on_select? DadbodUI.PickerSelect
---@return boolean
function M.show(opts, on_select)
  local ok, Snacks = pcall(require, 'snacks')
  if not ok then
    return false
  end
  local select = on_select or utils.connect

  local picker_opts = {
    title = 'Connections',
    finder = function()
      return utils.build_items()
    end,
    format = function(item, _)
      local result = { { item.label, 'SnacksPickerFile' } }
      if item.is_connected then
        result[#result + 1] = { ' ●', 'SnacksPickerMatch' }
      end
      result[#result + 1] = { '  ' .. item.url, 'SnacksPickerComment' }
      return result
    end,
    confirm = function(picker, item)
      picker:close()
      select(item --[[@as DadbodUI.PickerItem|nil]])
    end,
  }
  Snacks.picker(vim.tbl_deep_extend('force', picker_opts, opts or {}))
  return true
end

return M
