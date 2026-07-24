-- Headless JSON-explain runner (wrap -> client -> decode -> tree)
--
-- The orchestration seam between the pure pieces: wrap the SQL in the
-- adapter's JSON EXPLAIN form, run it through the adapter's OWN client
-- (`bridge.query_command` + `run_many` -- no `:DB`, no `.dbout` window, main
-- loop never blocks), decode the stdout into a normalized plan, and open the
-- tree. Both entry points funnel here: the query-buffer keymap
-- (`Query:explain_tree`) and the api verb (`api.explain_tree`).
--
-- Errors at every stage surface as user-facing notifications: unsupported
-- adapter, client failure (the server's stderr is the interesting part),
-- unparseable output.

---@private
local bridge = require('dadbod-ui.bridge')
---@private
local explain = require('dadbod-ui.explain')
---@private
local notify = require('dadbod-ui.notifications')
---@private
local plan_mod = require('dadbod-ui.explain.plan')
---@private
local tree = require('dadbod-ui.explain.tree')

local M = {}

---@class DadbodUI.ExplainTreeRun
---@field scheme string  the connection's adapter scheme
---@field conn string    the RESOLVED connection url (a live connection)
---@field sql string     the (bind-param substituted) SQL to explain
---@field analyze? boolean  run the executing JSON form (rolled back for DML where the dialect allows)

--- Explain `run.sql` and open the plan tree. Asynchronous: returns after
--- spawning the client; the tree opens (or the error surfaces) from the exit
--- callback on the main loop.
---@param run DadbodUI.ExplainTreeRun
---@return nil
function M.open_tree(run)
  local fail = notify.error
  local wrapped, err = explain.wrap(run.scheme, run.sql, { format = 'json', analyze = run.analyze })
  if wrapped == nil then
    return fail(err)
  end
  bridge.run_many({ bridge.query_command(run.conn, wrapped, explain.json_args(run.scheme)) }, function(results)
    local result = results[1]
    if result == nil then
      return fail('explain failed: could not run the adapter client (is it installed?)')
    end
    if result.code ~= 0 then
      local detail = vim.trim(result.stderr or '')
      return fail('explain failed: ' .. (detail ~= '' and detail or ('client exited with code ' .. result.code)))
    end
    local plan, decode_err = plan_mod.decode(run.scheme, result.stdout or '')
    if plan == nil then
      -- Some clients report SQL errors on stderr while still exiting 0; the
      -- server's message beats "could not decode" when it exists.
      local detail = vim.trim(result.stderr or '')
      return fail(detail ~= '' and ('explain failed: ' .. detail) or decode_err)
    end
    tree.open(plan)
  end)
end

return M
