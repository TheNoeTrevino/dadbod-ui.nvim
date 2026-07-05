-- Connection picker: Telescope.nvim backend
--
-- Requires Telescope.nvim (https://github.com/nvim-telescope/telescope.nvim).
-- `<CR>` connects the selected connection.

---@type DadbodUI.PickerBackend
---@diagnostic disable-next-line: missing-fields
local M = {}

--- Show the Telescope picker.
---@param items DadbodUI.PickerItem[]
---@param opts? table  Telescope picker overrides
---@param on_select DadbodUI.PickerSelect
---@return boolean
function M.show(items, opts, on_select)
  if not pcall(require, 'telescope') then
    return false
  end

  local pickers = require('telescope.pickers')
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')
  local entry_display = require('telescope.pickers.entry_display')

  local max_label_width = 0
  for _, item in ipairs(items) do
    max_label_width = math.max(max_label_width, #item.label)
  end

  local displayer = entry_display.create({
    separator = ' ',
    items = {
      { width = max_label_width },
      { width = 1 },
      { remaining = true },
    },
  })

  ---@param entry { value: DadbodUI.PickerItem }
  local function make_display(entry)
    return displayer({
      { entry.value.label, 'TelescopeResultsIdentifier' },
      { entry.value.is_connected and '●' or ' ', 'TelescopeResultsNumber' },
      { entry.value.url, 'TelescopeResultsComment' },
    })
  end

  local picker_opts = vim.tbl_deep_extend('force', {
    prompt_title = 'Connections',
    finder = finders.new_table({
      results = items,
      entry_maker = function(item)
        return { value = item, display = make_display, ordinal = item.text }
      end,
    }),
    sorter = conf.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        on_select(selection and selection.value)
      end)
      return true
    end,
  }, opts or {})

  pickers.new({}, picker_opts):find()
  return true
end

return M
