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

---@type DadbodUI.ExplainModule
---@diagnostic disable-next-line: missing-fields
local M = {}

---@private
-- `{sql}` is substituted with the user's query (see `subst`). `plain` is the
-- planner estimate (never executes); `analyze` runs the query for real timings
-- and is intentionally absent for adapters that have no executing EXPLAIN form.
---@type table<string, { plain: string, analyze?: string }>
local templates = {
  postgresql = { plain = 'EXPLAIN {sql}', analyze = 'EXPLAIN ANALYZE {sql}' },
  mysql = { plain = 'EXPLAIN {sql}', analyze = 'EXPLAIN ANALYZE {sql}' },
  -- MariaDB spells its executing form `ANALYZE <stmt>` (no `EXPLAIN` prefix).
  mariadb = { plain = 'EXPLAIN {sql}', analyze = 'ANALYZE {sql}' },
  -- SQLite's `EXPLAIN QUERY PLAN` is the high-level plan; bare `EXPLAIN` dumps
  -- VDBE bytecode and there is no executing/timed form, so no `analyze`.
  sqlite = { plain = 'EXPLAIN QUERY PLAN {sql}' },
  clickhouse = { plain = 'EXPLAIN {sql}' },
  -- Oracle populates PLAN_TABLE then renders it -- two statements, run together
  -- (the engine's multi-statement paths handle the `;`-separated pair).
  oracle = { plain = 'EXPLAIN PLAN FOR {sql};\nSELECT * FROM TABLE(DBMS_XPLAN.DISPLAY);' },
}

---@private
-- Raw-scheme aliases -> the canonical template key. `entry.scheme` is already
-- canonical (postgres -> postgresql), but normalize defensively so a caller
-- passing a raw scheme still resolves.
local aliases = {
  postgres = 'postgresql',
  sqlite3 = 'sqlite',
}

---@private
---@param scheme string
---@return string
local function canonical(scheme)
  return aliases[scheme] or scheme
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
  return templates[canonical(scheme)] ~= nil
end

--- The canonical schemes that support an explain plan, sorted -- for building a
--- clear "not supported for X (supported: ...)" error, or feature-gating a UI.
---@return string[]
function M.supported_schemes()
  local names = vim.tbl_keys(templates)
  table.sort(names)
  return names
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
  local key = canonical(scheme)
  local template = templates[key]
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
      return nil, string.format('EXPLAIN ANALYZE is not supported for adapter %s', key)
    end
    return subst(template.analyze, sql)
  end
  return subst(template.plain, sql)
end

return M
