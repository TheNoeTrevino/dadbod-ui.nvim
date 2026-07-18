-- Statement classification over the adapter specs (#101)
--
-- One module that answers, from one place, what kind of statement we are
-- looking at:
--
--   * is it changing      -- does it mutate anything
--   * is it dangerous     -- DROP/TRUNCATE, or an UPDATE/DELETE with no WHERE
--   * is it a plain SELECT / does it already carry a paging clause
--
-- Dangerous is a subset of changing: everything dangerous mutates, not
-- everything that mutates is dangerous. The last question is deliberately two
-- facts, not one: the paginator wants "plain SELECT AND not already paged"
-- (appending a clause is safe), but a transformer that wraps the query in a
-- subquery only needs "plain SELECT", and one that strips paging only needs
-- "already paged".
--
-- Classification is a keyword heuristic over the SQL text with comments,
-- string literals and quoted identifiers stripped first -- NOT a parser. It is
-- deliberately conservative in the safe direction: a false "changing" blocks a
-- read on a read-only connection (annoying), a false "not changing" would let
-- a write through (unsafe).
--
-- The shared SQL core lives here; dialects extend it through the adapter
-- spec's `statements` field (oracle adds PURGE). An adapter with NO
-- `statements` field is not SQL (mongodb runs shell-syntax commands) or is
-- unknown, and `classify` returns nil -- "cannot tell" -- rather than guess.
-- Consumers that know their SQL is generic (e.g. the paginator handling a
-- user-registered adapter) can fall back to `classify_sql`, the bare core.

---@class DadbodUI.ClassifierModule
---@field classify fun(stmt: DadbodUI.Statement): DadbodUI.Classification|nil
---@field classify_sql fun(sql: string, patterns?: DadbodUI.StatementPatterns): DadbodUI.Classification

--- The classify() input: which dialect to read the SQL as, and the SQL itself.
---@class DadbodUI.Statement
---@field adapter DadbodUI.AdapterType|string  canonical adapter name or alias
---@field sql string

---@class DadbodUI.Classification
---@field is_changing boolean      the statement mutates something
---@field is_dangerous boolean     DROP/TRUNCATE, or UPDATE/DELETE with no WHERE (implies is_changing)
---@field is_plain_select boolean  a single plain row-returning SELECT
---@field is_paginated boolean     a paging clause (LIMIT/OFFSET/FETCH/TOP) is already present

---@private
local adapters = require('dadbod-ui.adapters')

---@type DadbodUI.ClassifierModule
---@diagnostic disable-next-line: missing-fields
local M = {}

---@private
-- The shared SQL core the per-adapter `statements` extensions build on.
-- `changing` is every statement-leading keyword that can mutate data, schema
-- or grants; `dangerous` the keywords that destroy without a row filter.
-- `paging` marks an existing paging clause; `not_plain` marks a SELECT that is
-- not a plain row-returning one (INTO writes, FOR UPDATE locks, procedure
-- output) -- the same word set the paginator guarded on before this module.
local CHANGING = {
  'insert',
  'update',
  'delete',
  'merge',
  'replace',
  'drop',
  'truncate',
  'alter',
  'create',
  'rename',
  'grant',
  'revoke',
  'call',
  'exec',
  'execute',
}
---@private
local DANGEROUS = { 'drop', 'truncate' }
---@private
local PAGING = { 'limit', 'offset', 'fetch', 'top' }
---@private
local NOT_PLAIN = { 'into', 'update', 'procedure' }

---@private
--- `sql` with comments removed and the contents of string literals / quoted
--- identifiers blanked to a space, so keyword matching cannot fire on quoted
--- data (`WHERE action = 'delete'`) or quoted names (`SELECT "update" ...`).
--- Handles `--` and `/* */` comments, `'`/`"`/backtick quoting with doubled-
--- quote escapes, and sqlserver `[bracket]` identifiers. Exotic quoting a
--- dialect adds on top (postgres $$dollar quoting$$) is out of scope: its
--- contents survive, which can only make classification MORE conservative.
---@param sql string
---@return string
local function strip(sql)
  local out = {}
  local i, n = 1, #sql
  while i <= n do
    local c = sql:sub(i, i)
    local two = sql:sub(i, i + 1)
    if two == '--' then
      local nl = sql:find('\n', i, true)
      i = nl or (n + 1)
    elseif two == '/*' then
      local close = sql:find('*/', i + 2, true)
      out[#out + 1] = ' '
      i = close and (close + 2) or (n + 1)
    elseif c == "'" or c == '"' or c == '`' then
      local j = i + 1
      while j <= n do
        if sql:sub(j, j) == c then
          if sql:sub(j + 1, j + 1) == c then -- doubled quote: escaped, keep going
            j = j + 2
          else
            break
          end
        else
          j = j + 1
        end
      end
      out[#out + 1] = ' '
      i = j + 1
    elseif c == '[' then
      local close = sql:find(']', i + 1, true)
      out[#out + 1] = ' '
      i = close and (close + 1) or (n + 1)
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

---@private
--- Does `text` (lowercase, stripped) contain `word` on word boundaries?
---@param text string
---@param word string
---@return boolean
local function has_word(text, word)
  return text:match('%f[%a]' .. word .. '%f[%A]') ~= nil
end

---@private
---@param text string
---@param words string[]|nil
---@return boolean
local function any_word(text, words)
  for _, word in ipairs(words or {}) do
    if has_word(text, word) then
      return true
    end
  end
  return false
end

--- Classify `sql` against the shared SQL core plus optional dialect
--- `patterns`. The adapter-agnostic fallback for SQL of unknown dialect;
--- `classify` is the front door when the adapter is known.
---@param sql string
---@param patterns? DadbodUI.StatementPatterns
---@return DadbodUI.Classification
function M.classify_sql(sql, patterns)
  patterns = patterns or {}
  local text = strip(sql):lower()

  -- Split on `;` (real ones -- literals are already blanked) so the per-
  -- statement checks below can't be fooled by neighbours: a WHERE in the first
  -- statement must not excuse a bare DELETE in the second.
  local statements = {}
  for statement in (text .. ';'):gmatch('(.-);') do
    if statement:match('%S') then
      statements[#statements + 1] = statement
    end
  end

  local changing = any_word(text, CHANGING) or any_word(text, patterns.changing)

  local dangerous = any_word(text, DANGEROUS) or any_word(text, patterns.dangerous)
  if not dangerous then
    for _, statement in ipairs(statements) do
      if (has_word(statement, 'update') or has_word(statement, 'delete')) and not has_word(statement, 'where') then
        dangerous = true
        break
      end
    end
  end

  local plain = #statements == 1 and statements[1]:match('^%s*select%f[%A]') ~= nil and not any_word(text, NOT_PLAIN)

  return {
    is_changing = changing or dangerous, -- dangerous is a subset of changing
    is_dangerous = dangerous,
    is_plain_select = plain,
    is_paginated = any_word(text, PAGING),
  }
end

--- Classify `stmt.sql` as `stmt.adapter`'s dialect, or nil when the adapter is
--- unknown or carries no `statements` patterns -- an honest "cannot tell",
--- never a guess (mongodb isn't SQL; a wrong guess on "is it dangerous" is how
--- a table gets dropped).
---@param stmt DadbodUI.Statement
---@return DadbodUI.Classification|nil
function M.classify(stmt)
  local spec = adapters.get(stmt.adapter)
  local patterns = spec and spec.statements
  if patterns == nil then
    return nil
  end
  return M.classify_sql(stmt.sql, patterns)
end

return M
