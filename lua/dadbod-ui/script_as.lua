-- "Script As" (SSMS-style DDL scripting)
--
-- A scriptable drawer node (a stored routine, a table) expands to a "Script As"
-- submenu whose leaves each script the object a different way (CREATE / ALTER /
-- DROP / EXECUTE / ...). Activating one prompts for a destination (a new query
-- buffer, or replacing / appending the current one), optionally fetches the
-- action's input from the database, builds the finished DDL via the adapter's
-- builder, and hands it to the query controller.
--
-- The capability is a flat list of actions on the adapter spec
-- (`routine_scripts.actions` / `table_scripts.actions`); each action is
-- `{ label, query?, args?, parse?, build? }`:
--   * `query(schema, name, kind)` -- SQL fetching this action's input, or absent
--     when the action builds from the name/kind alone (no DB round-trip, e.g. a
--     name-only DROP);
--   * `args` -- CLI args replacing the adapter's for this fetch, when the query
--     needs different output formatting than the adapter's introspection queries;
--   * `parse(lines)` -- turn the query's raw output into whatever `build` wants
--     (defaults to reassembling statement text via `M.text`);
--   * `build(ctx)` -- produce the final DDL from `{ schema, name, kind, data }`.
-- Everything database-specific lives on the adapter; this module owns only the
-- destination prompt, the async fetch and the hand-off, so an adapter opts in by
-- defining the capability and needs no code here. It never branches on `kind`.

local bridge = require('dadbod-ui.bridge')
local schemas = require('dadbod-ui.schemas')
local state = require('dadbod-ui.state')
local notifications = require('dadbod-ui.notifications')

---@class DadbodUI.ScriptAsModule
local M = {}

--- Where a scripted object's DDL lands, offered after an action is picked.
---@type { label: string, dest: 'new'|'replace'|'append' }[]
M.destinations = {
  { label = 'Open in new query buffer', dest = 'new' },
  { label = 'Replace current query buffer', dest = 'replace' },
  { label = 'Append to current query buffer', dest = 'append' },
}

--- Run one scripting `action` against an object: prompt for a destination, build
--- the DDL (fetching from the database first when the action needs it) and write
--- it there. A cancelled prompt or a fetch error is a clean no-op (the latter
--- notifies).
---@param opts { entry: DadbodUI.ConnectionEntry, schema: string, name: string, kind: 'procedure'|'function'|'table', action: DadbodUI.ScriptAction, query: DadbodUI.Query }
---@return nil
function M.run(opts)
  local action = opts.action
  -- Use the query controller's injectable picker (same backend the edit flow
  -- uses), not `vim.ui.select` directly, so a test can drive this without a real UI.
  local select = opts.query.select or vim.ui.select
  select(M.destinations, {
    prompt = string.format('%s %s.%s ->', action.label, opts.schema, opts.name),
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice then
      return
    end
    M.produce(opts, function(text)
      opts.query:write_script(opts.entry, choice.dest, text, { table = opts.name, schema = opts.schema })
    end)
  end)
end

--- Reassemble a fetched query's raw output lines into statement text: drop the
--- blank framing top and bottom, keep the interior. This is the default `parse`
--- for an action whose `query` returns statement/definition text (the common
--- case); actions that fetch structured data (e.g. a parameter list) supply their
--- own `parse`.
---@param lines string[]
---@return string
function M.text(lines)
  local first, last
  for i, line in ipairs(lines) do
    if vim.trim(line) ~= '' then
      first = first or i
      last = i
    end
  end
  if first == nil then
    return ''
  end
  return table.concat(lines, '\n', first, last)
end

--- The default `build`: hand back the fetched (and parsed) data unchanged. Used
--- by actions whose statement was built entirely by their `query` (e.g. every
--- postgres action, or sqlserver `CREATE To`), so they need no `build` -- the
--- symmetric counterpart of `M.text` being the default `parse`.
---@param ctx DadbodUI.ScriptCtx
---@return any
function M.fetched(ctx)
  return ctx.data
end

--- Build the script text for `opts.action` and invoke `cb(text)`. An action with
--- a `query` fetches its input (parsed via `action.parse`, else `M.text`) before
--- building (via `action.build`, else `M.fetched`); a query-less action (e.g. a
--- name-only DROP) builds synchronously. `cb` is not called when the build yields
--- nothing (a failed fetch notifies).
---@param opts { entry: DadbodUI.ConnectionEntry, schema: string, name: string, kind: 'procedure'|'function'|'table', action: DadbodUI.ScriptAction }
---@param cb fun(text: string): nil
---@return nil
function M.produce(opts, cb)
  local action = opts.action
  ---@type DadbodUI.ScriptCtx
  local ctx = { schema = opts.schema, name = opts.name, kind = opts.kind }
  local build = action.build or M.fetched

  local function emit(text)
    if text == nil or text == '' then
      notifications.error(string.format('Could not script %s.%s.', opts.schema, opts.name))
      return
    end
    cb(text)
  end

  local sql = action.query and action.query(opts.schema, opts.name, opts.kind)
  if sql == nil then
    return emit(build(ctx))
  end
  local conn = opts.entry.conn
  if conn == nil or conn == '' then
    notifications.error('Connect to the database before scripting.')
    return
  end
  -- Resolved only on the fetch path (a query-less action never needs it).
  local scheme_info = schemas.get(opts.entry.scheme, state.config())
  bridge.run_many({ schemas.command_spec(conn, scheme_info, sql, action.args) }, function(results)
    ctx.data = (action.parse or M.text)(schemas.result_lines(results[1]))
    emit(build(ctx))
  end)
end

return M
