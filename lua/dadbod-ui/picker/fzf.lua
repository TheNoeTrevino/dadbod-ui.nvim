-- Connection picker: fzf-lua backend
--
-- Requires fzf-lua (https://github.com/ibhagwan/fzf-lua).
-- `<CR>` connects the selected connection.

---@type DadbodUI.PickerBackend
---@diagnostic disable-next-line: missing-fields
local M = {}

--- Show the fzf-lua picker.
---@param items DadbodUI.PickerItem[]
---@param opts? table  fzf-lua overrides
---@param on_select DadbodUI.PickerSelect
---@return boolean
function M.show(items, opts, on_select)
  local ok, fzf = pcall(require, 'fzf-lua')
  if not ok then
    return false
  end

  -- fzf works on display strings, so selections come back as text; map them
  -- back to their items through a lookup.
  local display_list = {}
  local lookup = {}
  for _, item in ipairs(items) do
    table.insert(display_list, item.text)
    lookup[item.text] = item
  end

  local fzf_opts = vim.tbl_deep_extend('force', {
    prompt = 'Connections> ',
    actions = {
      default = function(selected)
        on_select(selected and lookup[selected[1]])
      end,
    },
  }, opts or {})

  fzf.fzf_exec(display_list, fzf_opts)
  return true
end

return M
