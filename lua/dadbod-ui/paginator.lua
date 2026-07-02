-- Per-adapter result-set pagination (data + rewrite)
--
-- Appends a LIMIT/OFFSET paging clause to a plain SELECT so result buffers can
-- show one page at a time and step through with `[` / `]`. Modelled on DBeaver's
-- approach: NOT a subquery wrap -- the clause is appended to the query string and
-- a guard bails out the moment the query already carries a paging clause or is
-- not a plain SELECT.
--
-- Two append styles, declared per scheme below (mirroring the scheme->config
-- shape of `dadbod-ui.table_helpers`):
--   * `limit_offset` -- `LIMIT <length> OFFSET <offset>` (postgres, sqlite,
--     clickhouse, bigquery)
--   * `limit_comma`  -- `LIMIT <offset>, <length>` (mysql, mariadb)
-- sqlserver (TOP injection) and oracle (ROWNUM) are left UNSUPPORTED for now --
-- DBeaver does these at the AST level / has oracle commented out -- so they are
-- absent from the table and `paginate` no-ops for them.

---@class DadbodUI.PaginatorModule
---@field supports fun(scheme: string): boolean
---@field paginate fun(scheme: string, sql: string, page: integer, page_size: integer): string|nil

---@type DadbodUI.PaginatorModule
---@diagnostic disable-next-line: missing-fields
local M = {}

---@private
-- scheme -> append style. Keyed by BOTH the raw scheme (entry.scheme, e.g.
-- `postgres`/`sqlite3`) and the canonical name, so a lookup works regardless of
-- which the caller holds.
local styles = {
  postgresql = 'limit_offset',
  postgres = 'limit_offset',
  sqlite = 'limit_offset',
  sqlite3 = 'limit_offset',
  clickhouse = 'limit_offset',
  bigquery = 'limit_offset',
  mysql = 'limit_comma',
  mariadb = 'limit_comma',
}

---@private
-- Words whose presence (case-insensitive, on a word boundary) means we must not
-- inject a paging clause: an existing LIMIT/OFFSET/FETCH/TOP would double-page,
-- and INTO/UPDATE/PROCEDURE mark statements that aren't plain row-returning
-- SELECTs. Ported from DBeaver's paging guard.
local guard = { 'limit', 'offset', 'fetch', 'top', 'into', 'update', 'procedure' }

--- Whether `scheme` has a paginator (i.e. pagination is supported for it).
---@param scheme string
---@return boolean
function M.supports(scheme)
  return styles[scheme] ~= nil
end

---@private
--- Is `sql` a single plain SELECT with no existing paging clause? `sql` is the
--- already trailing-`;`-stripped query. Rejects multi-statement input (an inner
--- `;`) and anything not starting with SELECT, then bails on any guard word.
---@param sql string
---@return boolean
local function paginatable(sql)
  local lower = sql:lower()
  if not lower:match('^%s*select%f[%A]') then
    return false
  end
  if lower:find(';', 1, true) then
    return false -- multiple statements; pagination targets a single SELECT
  end
  for _, kw in ipairs(guard) do
    if lower:match('%f[%a]' .. kw .. '%f[%A]') then
      return false
    end
  end
  return true
end

--- The `sql` rewritten with the adapter's paging clause for `page` (1-based) at
--- `page_size` rows, or nil when the adapter is unsupported or the query already
--- pages / is not a plain SELECT (the caller then runs it unmodified). Offset is
--- `(page - 1) * page_size`.
---@param scheme string
---@param sql string
---@param page integer  1-based page number
---@param page_size integer  rows per page
---@return string|nil
function M.paginate(scheme, sql, page, page_size)
  local style = styles[scheme]
  if style == nil then
    return nil
  end
  local trimmed = (sql:gsub('%s*;?%s*$', ''))
  if not paginatable(trimmed) then
    return nil
  end
  local offset = (page - 1) * page_size
  if style == 'limit_comma' then
    return string.format('%s LIMIT %d, %d', trimmed, offset, page_size)
  end
  return string.format('%s LIMIT %d OFFSET %d', trimmed, page_size, offset)
end

return M
