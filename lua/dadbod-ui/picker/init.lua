-- Connection picker
--
-- An interactive list of every discovered connection; `<CR>` connects the
-- selection. Routes to a picker backend by `config.picker`:
--   * 'auto' (default): try Snacks.nvim, Telescope.nvim, fzf-lua, then fall
--     back to vim.ui.select
--   * 'snacks' | 'telescope' | 'fzf': that plugin only (warns when missing)
--   * 'fallback': vim.ui.select
-- One file per backend; `utils.lua` holds the shared item building + select
-- actions. Reached through `require('dadbod-ui.api').pick()` (connect on
-- `<CR>`), `api.execute_pick(sql)` (run `sql` against the pick) and
-- `api.explain_pick(sql)` (run `sql`'s EXPLAIN plan against the pick).

---@class DadbodUI.PickerRouter
---@field show fun(opts?: table, on_select?: DadbodUI.PickerSelect)
---@field execute fun(sql: string, opts?: table)
---@field explain fun(sql: string, opts?: DadbodUI.ExplainOpts, picker_opts?: table)

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
---@param items DadbodUI.PickerItem[]
---@param opts? table
---@param on_select DadbodUI.PickerSelect
local function show_auto(items, opts, on_select)
  for _, name in ipairs({ 'snacks', 'telescope', 'fzf' }) do
    if backend(name).show(items, opts, on_select) then
      return
    end
  end
  backend('fallback').show(items, opts, on_select)
end

--- Open the connection picker. `opts` is passed straight to the underlying
--- picker implementation, so its shape depends on the configured backend
--- (e.g. a `snacks.picker.Config` for snacks). `on_select` overrides what
--- `<CR>` does with the picked connection (default: connect it).
---@param opts? table
---@param on_select? DadbodUI.PickerSelect
function M.show(opts, on_select)
  local utils = require('dadbod-ui.picker.utils')
  local items = utils.build_items()
  if #items == 0 then
    return notifications.info('No connections found')
  end
  on_select = on_select or utils.connect

  local picker_type = require('dadbod-ui.state').config().picker or 'auto'
  if picker_type == 'auto' then
    return show_auto(items, opts, on_select)
  end

  if not backend(picker_type).show(items, opts, on_select) then
    notifications.warn(string.format("picker '%s' is not available", picker_type))
  end
end

--- Open the connection picker with `<CR>` rebound to run `sql` against the
--- picked connection (through dadbod's `:DB`, opening the `.dbout` window).
--- Rejects empty sql up front, before any picker is shown.
---@param sql string
---@param opts? table
function M.execute(sql, opts)
  if type(sql) ~= 'string' or vim.trim(sql) == '' then
    return notifications.error('No sql to execute')
  end
  M.show(opts, require('dadbod-ui.picker.utils').execute_action(sql))
end

--- Open the connection picker with `<CR>` rebound to run `sql`'s EXPLAIN plan
--- against the picked connection, wrapped in that adapter's own EXPLAIN syntax
--- (through dadbod's `:DB`, opening the `.dbout` window). When `opts.analyze`
--- is not specified, prompts for the EXPLAIN / EXPLAIN ANALYZE variant first
--- (vim.ui.select -- a two-item choice, so the full backend chain would be
--- overkill); pass `analyze = true|false` to skip the prompt.
---@param sql string
---@param opts? DadbodUI.ExplainOpts
---@param picker_opts? table
function M.explain(sql, opts, picker_opts)
  if type(sql) ~= 'string' or vim.trim(sql) == '' then
    return notifications.error('No sql to explain')
  end
  local utils = require('dadbod-ui.picker.utils')

  if opts ~= nil and opts.analyze ~= nil then
    return M.show(picker_opts, utils.explain_action(sql, opts))
  end

  vim.ui.select({ 'EXPLAIN', 'EXPLAIN ANALYZE (runs the query)' }, {
    prompt = 'Explain variant',
  }, function(choice)
    if choice == nil then
      return
    end
    local explain_opts = vim.tbl_extend('force', opts or {}, { analyze = choice ~= 'EXPLAIN' })
    M.show(picker_opts, utils.explain_action(sql, explain_opts))
  end)
end

return M
