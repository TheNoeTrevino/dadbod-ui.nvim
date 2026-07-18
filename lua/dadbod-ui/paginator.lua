-- Per-adapter result-set pagination (data + rewrite)
--
-- Appends a LIMIT/OFFSET paging clause to a plain SELECT so result buffers can
-- show one page at a time and step through with `[` / `]`. This is NOT a subquery
-- wrap -- the clause is appended to the query string and a guard bails out the
-- moment the query already carries a paging clause or is not a plain SELECT.
--
-- Two append styles, declared per adapter (the spec's `pagination` field):
--   * `limit_offset` -- `LIMIT <length> OFFSET <offset>` (postgres, sqlite,
--     clickhouse, bigquery)
--   * `limit_comma`  -- `LIMIT <offset>, <length>` (mysql, mariadb)
-- sqlserver (TOP injection) and oracle (ROWNUM) are left UNSUPPORTED for now --
-- they would require clause-level (AST) rewriting rather than a simple appended
-- clause -- so their specs carry no `pagination` and `paginate` no-ops for them.

---@class DadbodUI.PaginatorModule
---@field supports fun(scheme: string): boolean
---@field paginate fun(scheme: string, sql: string, page: integer, page_size: integer): string|nil

---@private
local adapters = require('dadbod-ui.adapters')
---@private
local classifier = require('dadbod-ui.classifier')

---@type DadbodUI.PaginatorModule
---@diagnostic disable-next-line: missing-fields
local M = {}

---@private
--- The adapter's LIMIT-clause style, or nil when pagination is unsupported.
---@param scheme string
---@return string|nil
local function style_for(scheme)
  local spec = adapters.get(scheme)
  return spec and spec.pagination or nil
end

--- Whether `scheme` has a paginator (i.e. pagination is supported for it).
---@param scheme string
---@return boolean
function M.supports(scheme)
  return style_for(scheme) ~= nil
end

---@private
--- Is `sql` a single plain SELECT with no existing paging clause? Asked of the
--- statement classifier as `scheme`'s dialect; a user-registered adapter with
--- a `pagination` style but no classifier patterns falls back to the generic
--- SQL core (declaring a LIMIT style is already a claim of SQL-ish syntax).
---@param scheme string
---@param sql string
---@return boolean
local function paginatable(scheme, sql)
  local c = classifier.classify({ adapter = scheme, sql = sql }) or classifier.classify_sql(sql)
  -- Appending a clause needs both facts: another LIMIT would double-page, and
  -- anything but a plain row-returning SELECT can't take one at all.
  return c.is_plain_select and not c.is_paginated
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
  local style = style_for(scheme)
  if style == nil then
    return nil
  end
  local trimmed = (sql:gsub('%s*;?%s*$', ''))
  if not paginatable(scheme, trimmed) then
    return nil
  end
  local offset = (page - 1) * page_size
  if style == 'limit_comma' then
    return string.format('%s LIMIT %d, %d', trimmed, offset, page_size)
  end
  return string.format('%s LIMIT %d OFFSET %d', trimmed, page_size, offset)
end

return M
