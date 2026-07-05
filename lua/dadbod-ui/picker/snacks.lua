-- Connection picker: Snacks.nvim backend
--
-- Requires Snacks.nvim (https://github.com/folke/snacks.nvim).
-- `<CR>` connects the selected connection.

---@type DadbodUI.PickerBackend
---@diagnostic disable-next-line: missing-fields
local M = {}

--- Show the Snacks picker.
---@param items DadbodUI.PickerItem[]
---@param opts? table  snacks.picker.Config overrides
---@param on_select DadbodUI.PickerSelect
---@return boolean
function M.show(items, opts, on_select)
  local ok, Snacks = pcall(require, 'snacks')
  if not ok then
    return false
  end

  local picker_opts = {
    title = 'Connections',
    finder = function()
      return items
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
      on_select(item --[[@as DadbodUI.PickerItem|nil]])
    end,
  }
  Snacks.picker(vim.tbl_deep_extend('force', picker_opts, opts or {}))
  return true
end

return M
