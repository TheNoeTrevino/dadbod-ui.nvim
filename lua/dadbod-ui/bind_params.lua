-- Bind-parameter detection, quoting and substitution
--
-- The pure, side-effect-free core of M9. This module scans a query for
-- placeholders (default `:name`) and owns the three testable pieces of the bind-
-- parameter flow -- detection, value quoting, and substitution -- while
-- `dadbod-ui.query` owns the interactive prompting and the `b:dbui_bind_params`
-- persistence. None of these functions touch a buffer, the engine, or config, so
-- they unit-test directly.
--
-- Behavior:
--   * Placeholders are matched with `vim.regex` against the user's Vim-regex
--     `bind_param_pattern`, so a custom pattern (e.g. `\$\d\+`) works without
--     rebuilding a regex by string concatenation.
--   * A placeholder is ignored when it sits inside a quoted span -- a single-quoted
--     string literal (`'... :id ...'`), a double-quoted identifier
--     (`"... :id ..."`), or a Postgres dollar-quoted body (`$$ ... :id ... $$`) --
--     or a comment (`-- :id`, `/* :id */`), consistently for BOTH detection and
--     substitution. A small lexer carries string, identifier, dollar-quote and
--     block-comment state across lines, so multi-line spans mask correctly. This
--     means an apostrophe inside `"customer's"` or a dollar-quoted body does not
--     flip string state and corrupt masking of the rest of the statement.
--   * The colon-prefix guard (so `value::text` casts are not seen as `:text`
--     placeholders) is a single "preceding char is not `:`" check rather than a
--     grouped capture, which keeps it pattern-agnostic.
--   * `quote()` escapes embedded single quotes (`O'Brien` -> `'O''Brien'`), and
--     passes NULL and decimals/negatives through bare, while still respecting an
--     already-quoted literal.

---@class DadbodUI.BindParamsModule
---@field quote fun(val: string): string
---@field detect fun(lines: string[], pattern: string): string[]
---@field substitute fun(lines: string[], values: table<string, string>, pattern: string): string[]

---@type DadbodUI.BindParamsModule
---@diagnostic disable-next-line: missing-fields
local M = {}

--- Quote a raw bind value for inlining into SQL. Bare (unquoted) when the value
--- is already a single-quoted literal, a number (integer/decimal, optional
--- leading `-`), or one of the bare keywords true/false/null; otherwise wrapped
--- in single quotes with embedded `'` doubled. An empty/blank value is the
--- caller's "leave the placeholder raw" signal and never reaches here.
---@param val string
---@return string
function M.quote(val)
  -- Already a single-quoted literal: trust it as-is (escape hatch for values the
  -- user pre-quoted).
  if val:match("^'.*'$") then
    return val
  end
  -- Numbers go in bare: integers and decimals, optionally negative.
  if val:match('^%-?%d+$') or val:match('^%-?%d+%.%d+$') then
    return val
  end
  -- Bare SQL keywords (case-insensitive).
  local lower = val:lower()
  if lower == 'true' or lower == 'false' or lower == 'null' then
    return val
  end
  -- Everything else is a string literal: single-quote and double embedded quotes.
  return "'" .. val:gsub("'", "''") .. "'"
end

---@private
--- The shared SQL quoting/comment lexer (dadbod-ui.sql_masks): per-line byte
--- masks that are truthy inside quoted spans and comments -- exactly where a
--- placeholder must NOT be detected or substituted. The lexer lives in its own
--- module so every SQL-reading consumer shares the same masking rules.
local build_masks = require('dadbod-ui.sql_masks').build

---@alias DadbodUI.BindOccurrence { name: string, s: integer, e: integer }

---@private
--- Build a per-line occurrence finder bound to `pattern`. The returned function
--- finds every placeholder in `line`, left to right, skipping any that sits in a
--- masked span (string literal or comment, per `mask`) or is immediately
--- preceded by `:` (so `::text` casts are not matched), and returns occurrences
--- with 0-based byte spans `[s, e)` so callers can rebuild the line. The compiled
--- regex is captured here (compiled once per detect/substitute call) -- its type
--- is left to inference because Neovim's `vim.regex` class is `@nodoc` and
--- cannot be named in an annotation.
---@param pattern string  a Vim regex (the resolved `bind_param_pattern`)
---@return fun(line: string, mask: boolean[]): DadbodUI.BindOccurrence[]
local function make_finder(pattern)
  local regex = vim.regex(pattern)
  return function(line, mask)
    local out = {}
    local offset = 0
    while offset <= #line do
      local rs, re = regex:match_str(line:sub(offset + 1))
      if rs == nil then
        break
      end
      local s = rs + offset
      local e = re + offset
      -- Preceding byte (1-based index `s`) must not be a colon, and the match
      -- must start outside any masked (string/comment) span.
      local prev = s > 0 and line:sub(s, s) or ''
      if prev ~= ':' and not mask[s + 1] then
        out[#out + 1] = { name = line:sub(s + 1, e), s = s, e = e }
      end
      -- Advance past this match; guard the zero-width case so we never loop.
      offset = e > s and e or s + 1
    end
    return out
  end
end

--- The distinct placeholder names in `lines`, in first-seen order. `pattern` is a
--- Vim regex (the resolved `bind_param_pattern`). Returns `{}` when none match.
---@param lines string[]
---@param pattern string
---@return string[]
function M.detect(lines, pattern)
  local find = make_finder(pattern)
  local masks = build_masks(lines)
  local seen = {}
  local names = {}
  for i, line in ipairs(lines) do
    for _, occ in ipairs(find(line, masks[i])) do
      if not seen[occ.name] then
        seen[occ.name] = true
        names[#names + 1] = occ.name
      end
    end
  end
  return names
end

--- Substitute `values` into `lines`, replacing each placeholder with its quoted
--- value. A name with no entry, or an empty/blank value, is left untouched -- a
--- blank value is the documented "treat the placeholder as a raw literal" escape
--- hatch. Occurrences inside string literals, comments, or after `:` are never
--- touched (detection and substitution share the same masking, so they agree).
---@param lines string[]
---@param values table<string, string>  name -> raw (unquoted) value
---@param pattern string
---@return string[]
function M.substitute(lines, values, pattern)
  local find = make_finder(pattern)
  local masks = build_masks(lines)
  local out = {}
  for i, line in ipairs(lines) do
    local occs = find(line, masks[i])
    local result = line
    -- Right to left so earlier spans keep their byte offsets as we splice.
    for idx = #occs, 1, -1 do
      local occ = occs[idx]
      local val = values[occ.name]
      if val ~= nil and vim.trim(val) ~= '' then
        result = result:sub(1, occ.s) .. M.quote(val) .. result:sub(occ.e + 1)
      end
    end
    out[#out + 1] = result
  end
  return out
end

return M
