-- Per-adapter EXPLAIN-plan templates (data + wrapping)
--
-- An explain plan is just a query wrapped in the adapter's EXPLAIN syntax, so
-- this module owns only the per-scheme wrapping rule -- execution reuses the
-- existing engine paths (`dadbod-ui.api`'s `query` / `execute`). It holds no
-- logic beyond turning a user's SQL into its EXPLAIN form for a given scheme,
-- mirroring the small, single-responsibility `table_helpers` data module.
--
-- Not every adapter supports an explain plan (SQL Server's SHOWPLAN is a
-- session-batch setting, BigQuery has no EXPLAIN, MongoDB uses a different call
-- shape), so `wrap` returns `nil, err` for an unsupported scheme rather than
-- guessing -- the caller surfaces that as a user error. `analyze` (which
-- actually RUNS the query to collect real timings) is a separate per-adapter
-- template: adapters without one reject `{ analyze = true }` explicitly.

---@class DadbodUI.ExplainOpts
---@field analyze? boolean  run the query and report real timings (EXPLAIN ANALYZE); errors when the adapter has no analyze form

---@class DadbodUI.ExplainModule
---@field supports fun(scheme: string): boolean
---@field supported_schemes fun(): string[]
---@field wrap fun(scheme: string, sql: string, opts?: DadbodUI.ExplainOpts): string|nil, string|nil

---@private
local adapters = require('dadbod-ui.adapters')

---@type DadbodUI.ExplainModule
---@diagnostic disable-next-line: missing-fields
local M = {}

---@private
--- The `{sql}`-templated explain forms for a scheme (the adapter spec's
--- `explain` field), or nil when the adapter has none. `plain` is the planner
--- estimate (never executes); `analyze` runs the query for real timings and is
--- intentionally absent for adapters with no executing EXPLAIN form.
---@param scheme string
---@return { plain: string, analyze?: string }|nil
local function templates_for(scheme)
  local spec = adapters.get(scheme)
  return spec and spec.explain or nil
end

---@private
--- Replace the literal `{sql}` placeholder in `template` with `sql`, using a
--- function replacement so `%` (and Lua pattern magic) in the user's query stays
--- literal -- same safe substitution the query buffer uses for table helpers.
---@param template string
---@param sql string
---@return string
local function subst(template, sql)
  return (template:gsub('{sql}', function()
    return sql
  end))
end

--- Whether `scheme` has an explain-plan template (accepts raw or canonical
--- schemes). False for adapters without EXPLAIN support (sqlserver, bigquery,
--- mongodb) and for anything unknown.
---@param scheme string
---@return boolean
function M.supports(scheme)
  return templates_for(scheme) ~= nil
end

--- The canonical adapter names that support an explain plan, sorted -- for
--- building a clear "not supported for X (supported: ...)" error, or
--- feature-gating a UI.
---@return string[]
function M.supported_schemes()
  return adapters.names('explain')
end

--- Wrap `sql` in `scheme`'s EXPLAIN syntax, returning the explain query. Returns
--- `nil, err` (an early, user-facing error) when the adapter has no explain
--- support, or when `opts.analyze` is set but the adapter has no executing
--- EXPLAIN form -- callers surface that verbatim rather than running a query the
--- adapter can't explain.
---@param scheme string
---@param sql string
---@param opts? DadbodUI.ExplainOpts
---@return string|nil explain_sql
---@return string|nil err
function M.wrap(scheme, sql, opts)
  opts = opts or {}
  local template = templates_for(scheme)
  if template == nil then
    return nil,
      string.format(
        'explain plan is not supported for adapter %s (supported: %s)',
        tostring(scheme),
        table.concat(M.supported_schemes(), ', ')
      )
  end
  if opts.analyze then
    if template.analyze == nil then
      return nil, string.format('EXPLAIN ANALYZE is not supported for adapter %s', adapters.canonical(scheme))
    end
    return subst(template.analyze, sql)
  end
  return subst(template.plain, sql)
end

return M
