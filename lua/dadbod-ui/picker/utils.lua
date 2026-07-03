-- Connection picker shared helpers
--
-- Item building + the select action shared by every picker backend
-- (snacks / telescope / fzf / fallback). Items are built from the api's
-- connection list, so the picker shows exactly what `api.list()` reports.

--- One pickable connection.
---@class DadbodUI.PickerItem
---@field idx number  position in the connection list
---@field score number  sort score (same as idx; snacks reads it)
---@field text string  formatted display text (also the fuzzy-match haystack)
---@field label string  `group/name`, or the bare name when ungrouped
---@field name string  display name
---@field group string  group name ('' when ungrouped)
---@field key_name string  unique key; what the select action connects
---@field url string  connection url
---@field is_connected boolean

--- The interface every backend implements. `show` returns false when the
--- backend's plugin is not installed, so the router can try the next one.
---@class DadbodUI.PickerBackend
---@field is_available fun(): boolean
---@field show fun(opts?: table): boolean

---@class DadbodUI.PickerUtils
---@field build_items fun(): DadbodUI.PickerItem[]
---@field connect fun(item: DadbodUI.PickerItem|nil)

local notifications = require('dadbod-ui.notifications')

---@type DadbodUI.PickerUtils
---@diagnostic disable-next-line: missing-fields
local M = {}

--- Build picker items from the discovered connections.
---@return DadbodUI.PickerItem[]
function M.build_items()
  local items = {}
  for i, info in ipairs(require('dadbod-ui.api').list()) do
    local label = info.group ~= '' and (info.group .. '/' .. info.name) or info.name
    table.insert(items, {
      idx = i,
      score = i,
      label = label,
      text = label .. (info.is_connected and ' (connected)' or '') .. '  ' .. info.url,
      name = info.name,
      group = info.group,
      key_name = info.key_name,
      url = info.url,
      is_connected = info.is_connected,
    })
  end
  return items
end

--- The `<CR>` action shared by every backend: connect the selection (a no-op
--- when already connected). Nil-safe so backends can pass a cancelled pick
--- straight through.
---@param item DadbodUI.PickerItem|nil
function M.connect(item)
  if item == nil then
    return
  end
  require('dadbod-ui.api').connect(item.key_name, function(ok, err)
    if not ok then
      return notifications.error(err or ('Failed to connect to ' .. item.label))
    end
    notifications.info('Connected to ' .. item.label)
  end)
end

return M
