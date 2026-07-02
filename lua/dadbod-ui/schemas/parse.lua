-- Shared parsing/escaping helpers for schema adapters
--
-- Internal helpers used by the per-adapter builders (and the dispatcher): Vim
-- list-slice emulation, blank detection, SQL identifier/literal escaping, the
-- routine-kind keyword map, and the `s:results_parser` port. These are ported
-- verbatim from vim-dadbod-ui's `autoload/db_ui/schemas.vim`; the slicing and
-- splitting rules encode each CLI's exact output framing and must not change.

local P = {}

---@private
-- Mimic Vim's list slice `list[from:to]`: 0-based, both bounds inclusive,
-- negative indices count from the end. `to` defaults to the last element (the
-- `list[from:]` form). Operates on a Lua 1-based array.
---@param list any[]
---@param from integer
---@param to? integer
---@return any[]
function P.vslice(list, from, to)
  local n = #list
  to = to or -1
  if from < 0 then
    from = n + from
  end
  if to < 0 then
    to = n + to
  end
  local out = {}
  for i = from, to do
    if i >= 0 and i < n then
      out[#out + 1] = list[i + 1]
    end
  end
  return out
end

---@private
---@param value string
---@return boolean
function P.blank(value)
  return vim.trim(value) == ''
end

---@private
-- Escape a value for embedding inside a single-quoted SQL string literal
-- (postgres / sqlserver / oracle): double every single quote. Used by the
-- routine-definition queries so a routine whose name/schema contains a quote is
-- looked up correctly instead of terminating the literal early.
---@param s string
---@return string
function P.sql_squote(s)
  return (s:gsub("'", "''"))
end

---@private
-- Escape a value for embedding inside a backtick-quoted MySQL identifier: double
-- every backtick. Used by `SHOW CREATE PROCEDURE/FUNCTION`.
---@param s string
---@return string
function P.my_backtick(s)
  return (s:gsub('`', '``'))
end

---@private
-- Escape a value for embedding inside a `[bracket]`-quoted SQL Server
-- identifier: double every closing bracket (the only delimiter char that can
-- appear inside one, since `[` needs no escaping in this quoting style). Used
-- to build a bracket-quoted `schema.name` for `OBJECT_ID('[schema].[name]')` so
-- a schema/routine name containing a space or dot resolves instead of coming
-- back NULL.
---@param s string
---@return string
function P.sql_bracket(s)
  return (s:gsub(']', ']]'))
end

---@private
-- Map a normalized routine kind ('procedure'|'function') to the SQL keyword used
-- by the `SHOW CREATE`/`GET_DDL`-style definition builders (mysql, oracle).
---@param kind string
---@return string
function P.routine_verb(kind)
  return kind == 'function' and 'FUNCTION' or 'PROCEDURE'
end

---@private
-- Port of `s:results_parser`. `delimiter` is a Vim regex (split is done with
-- `vim.fn.split`, identical to the original). For `min_len == 1` the rows are
-- returned untouched (sans blanks); otherwise each row is split into fields and
-- only the rows of the expected width are kept -- when `min_len == 0` that width
-- is the widest row seen.
---@param results string[]
---@param delimiter string
---@param min_len integer
---@return any[]
function P.results_parser(results, delimiter, min_len)
  if min_len == 1 then
    return vim.tbl_filter(function(row)
      return not P.blank(row)
    end, results)
  end

  local mapped = vim.tbl_map(function(row)
    return vim.tbl_filter(function(field)
      return not P.blank(field)
    end, vim.fn.split(row, delimiter))
  end, results)

  if min_len > 1 then
    return vim.tbl_filter(function(fields)
      return #fields == min_len
    end, mapped)
  end

  local max_len = 0
  for _, fields in ipairs(mapped) do
    max_len = math.max(max_len, #fields)
  end
  return vim.tbl_filter(function(fields)
    return #fields == max_len
  end, mapped)
end

return P
