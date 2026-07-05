-- Scripting API: query-buffer verbs
--
-- `require('dadbod-ui.api').buf` -- every verb here acts on the CURRENT
-- dadbod-ui query buffer (its connection, text, visual selection and
-- bind-param context), the `vim.lsp.buf` convention. These are the Lua duals
-- of the query buffer's mappings/commands: what you bind to keys or run
-- interactively inside one. For the callable-anywhere verbs that address a
-- connection by name, see `dadbod-ui.api`.

---@class DadbodUI.ApiBufModule
---@field switch fun(name?: string): boolean, string|nil
---@field find fun()
---@field rename fun()
---@field execute fun(transform?: DadbodUI.SqlTransform)
---@field execute_selection fun(transform?: DadbodUI.SqlTransform)
---@field cancel fun()
---@field last_query_info fun()
---@field explain fun(opts?: DadbodUI.ExplainOpts)
---@field explain_selection fun(opts?: DadbodUI.ExplainOpts)
---@field export fun()
---@field export_selection fun()

local resolve = require('dadbod-ui.api.resolve')

---@private
---@type DadbodUI.ApiBufModule
---@diagnostic disable-next-line: missing-fields
local M = {}

--- Switch the current query buffer to connection `name` without prompting. The
--- current buffer must already be a dadbod-ui query buffer; its text, table/schema
--- and bind-param context ride across to the new connection. With no `name`, falls
--- back to the interactive
--- picker (and returns true, as the pick is async). Returns `false, err` when the
--- name is unknown, the current buffer is not a query buffer, or there is no
--- other connection to switch to.
---@param name? string
---@return boolean ok
---@return string|nil err
function M.switch(name)
  if name == nil then
    require('dadbod-ui').switch_buffer()
    return true
  end
  -- Resolve through the api's own addressing (key_name / group/name / bare) and
  -- hand the drawer an unambiguous key_name, so a name reused across groups
  -- switches to exactly the one asked for.
  local entry = resolve(name)
  if entry == nil then
    return false, 'no connection named ' .. tostring(name)
  end
  local ok, err = require('dadbod-ui').switch_buffer(entry.key_name)
  return ok == true, err
end

--- Find/adopt the query buffer for the current db context.
function M.find()
  require('dadbod-ui').find_buffer()
end

--- Rename the current query buffer's on-disk file.
function M.rename()
  require('dadbod-ui').rename_buffer()
end

--- Execute the whole current query buffer through dadbod, opening the `.dbout`
--- result window -- the Lua equivalent of the `execute` mapping in normal mode.
--- Pass an optional `transform` to rewrite the runnable SQL before it is
--- dispatched -- it receives the buffer's SQL (already bind-param substituted) and
--- returns the SQL to run instead (e.g. wrapping it in EXPLAIN). Returning nil, or
--- omitting `transform`, runs the buffer unchanged. The transform is synchronous:
--- to drive it from a picker, open the picker first and call `execute` from
--- its callback.
---
--- >lua
---   require('dadbod-ui.api').buf.execute(function(sql)
---     return 'EXPLAIN ANALYZE\n' .. sql
---   end)
--- <
---@param transform? DadbodUI.SqlTransform
function M.execute(transform)
  require('dadbod-ui').execute_query(transform)
end

--- Execute the current visual selection through dadbod -- the Lua equivalent of
--- the `execute` mapping in visual mode. Takes the same optional `transform` as
--- `execute`, applied to the selected SQL.
---@param transform? DadbodUI.SqlTransform
function M.execute_selection(transform)
  require('dadbod-ui').execute_selection(transform)
end

--- Cancel the running async query for the current query buffer.
function M.cancel()
  require('dadbod-ui').cancel_query()
end

--- Echo the last executed query and its runtime.
function M.last_query_info()
  require('dadbod-ui').print_last_query_info()
end

--- Explain the current query buffer's SQL and open the plan in the `.dbout`
--- window -- the explain dual of `execute`, operating on the focused buffer
--- rather than a name+sql pair. Reuses the buffer's connection and bind-param
--- context (placeholders are prompted, then the substituted query is wrapped in
--- the adapter's EXPLAIN syntax). Pass `{ analyze = true }` for `EXPLAIN ANALYZE`
--- (which RUNS the query). An unsupported adapter / analyze form, or a
--- non-query buffer, surfaces as a notification. The Lua equivalent of an
--- explain-query mapping.
---@param opts? DadbodUI.ExplainOpts
function M.explain(opts)
  require('dadbod-ui').explain_query(opts)
end

--- Explain the current visual selection and open the plan in the `.dbout` window
--- -- the explain dual of `execute_selection`. Same connection/bind-param reuse
--- and `opts.analyze` behavior as `explain`.
---@param opts? DadbodUI.ExplainOpts
function M.explain_selection(opts)
  require('dadbod-ui').explain_selection(opts)
end

--- Export the current query buffer's results to a file: run its SQL and write the
--- rows in a chosen format, prompting for format + path -- the query-buffer dual
--- of the api's `export` (which takes an explicit name+sql+path) and the
--- counterpart to `dbout.export` (which works on the `.dbout` result buffer).
--- Reuses the buffer's connection + bind-param context.
function M.export()
  require('dadbod-ui').export_query()
end

--- Export the current visual selection's results to a file -- the export dual of
--- `execute_selection`. Same prompt + connection/bind-param reuse as `export`.
function M.export_selection()
  require('dadbod-ui').export_selection()
end

return M
