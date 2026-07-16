-- Connection picker shared helpers
--
-- Item building + the select action shared by every picker backend
-- (snacks / telescope / fzf / fallback). Items are built from the api's
-- connection list, so the picker shows exactly what `api.list()` reports.

--- One pickable connection.
---@class DadbodUI.PickerItem
---@field score number  sort score (list position; snacks reads it)
---@field text string  formatted display text (also the fuzzy-match haystack)
---@field label string  `group/name`, or the bare name when ungrouped
---@field name string  display name
---@field group string  group name ('' when ungrouped)
---@field key_name string  unique key; what the select action connects
---@field url string  connection url
---@field is_connected boolean

--- The `<CR>` action a backend fires with the picked item (nil = cancelled).
---@alias DadbodUI.PickerSelect fun(item: DadbodUI.PickerItem|nil)

--- The interface every backend implements. The router builds the (non-empty)
--- item list and the `<CR>` action once and passes both in; `show` returns
--- false when the backend's plugin is not installed, so the router can try
--- the next one.
---@class DadbodUI.PickerBackend
---@field show fun(items: DadbodUI.PickerItem[], opts?: table, on_select: DadbodUI.PickerSelect): boolean

---@class DadbodUI.PickerUtils
---@field build_items fun(): DadbodUI.PickerItem[]
---@field connect DadbodUI.PickerSelect
---@field execute_action fun(sql: string): DadbodUI.PickerSelect
---@field explain_action fun(sql: string, opts?: DadbodUI.ExplainOpts): DadbodUI.PickerSelect

local notifications = require('dadbod-ui.notifications')
local utils = require('dadbod-ui.utils')

---@type DadbodUI.PickerUtils
---@diagnostic disable-next-line: missing-fields
local M = {}

--- Build picker items from the discovered connections.
---@return DadbodUI.PickerItem[]
function M.build_items()
  local items = {}
  -- inline: require cycle (api launches the picker)
  for i, info in ipairs(require('dadbod-ui.api').list()) do
    local label = utils.display_name(info.name, info.group)
    table.insert(items, {
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

--- The default `<CR>` action: connect the selection (a no-op when already
--- connected). Nil-safe so backends can pass a cancelled pick straight through.
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

--- Build a nil-safe `<CR>` action around `run(item) -> ok, err`, surfacing a
--- failure as an error notification ("Failed to {verb} against {label}").
---@param verb string
---@param run fun(item: DadbodUI.PickerItem): boolean, string|nil
---@return DadbodUI.PickerSelect
local function action(verb, run)
  return function(item)
    if item == nil then
      return
    end
    local ok, err = run(item)
    if not ok then
      notifications.error(err or ('Failed to ' .. verb .. ' against ' .. item.label))
    end
  end
end

--- Build a `<CR>` action that executes `sql` against the selection through
--- dadbod's `:DB` (connecting first if needed), opening the `.dbout` result
--- window -- the picker dual of `api.execute`.
---@param sql string
---@return DadbodUI.PickerSelect
function M.execute_action(sql)
  return action('execute', function(item)
    return require('dadbod-ui.api').execute(item.key_name, sql)
  end)
end

--- Build a `<CR>` action that runs `sql`'s EXPLAIN plan against the selection,
--- wrapped in the picked adapter's own EXPLAIN syntax -- the picker dual of
--- `api.explain_execute`. An adapter without explain (or analyze) support
--- surfaces as an error notification.
---@param sql string
---@param opts? DadbodUI.ExplainOpts
---@return DadbodUI.PickerSelect
function M.explain_action(sql, opts)
  return action('explain', function(item)
    return require('dadbod-ui.api').explain_execute(item.key_name, sql, opts)
  end)
end

return M
