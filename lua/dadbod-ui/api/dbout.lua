-- Scripting API: result-buffer verbs
--
-- `require('dadbod-ui.api').dbout` -- every verb here acts on the CURRENT
-- `.dbout` result buffer, the `vim.lsp.buf` convention. For the
-- callable-anywhere verbs that address a connection by name, see
-- `dadbod-ui.api`; for the query-buffer verbs, see `dadbod-ui.api.buf`.

---@class DadbodUI.ApiDboutModule
---@field export fun(page_choice?: 'full'|'current')

---@private
---@type DadbodUI.ApiDboutModule
---@diagnostic disable-next-line: missing-fields
local M = {}

--- Interactively export the current `.dbout` result buffer to a file (prompts for
--- format + path). `page_choice`
--- 'current' exports only the on-screen page of a paginated result; 'full' (the
--- default) exports the whole query. Use the api's `export` for a headless,
--- prompt-free export driven by a connection name + SQL.
---@param page_choice? 'full'|'current'
function M.export(page_choice)
  require('dadbod-ui.export').export_interactive(vim.api.nvim_get_current_buf(), nil, page_choice)
end

return M
