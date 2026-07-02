---@mod dadbod-ui.bind_params  Bind-parameter detection, quoting and substitution
---
--- The pure, side-effect-free core of M9. vim-dadbod-ui scans a query for
--- placeholders (default `:name`), prompts for each, and substitutes the quoted
--- values before handing the SQL to the engine. This module owns the three
--- testable pieces of that flow -- detection, value quoting, and substitution --
--- while `dadbod-ui.query` owns the interactive prompting and the
--- `b:dbui_bind_params` persistence. None of these functions touch a buffer, the
--- engine, or config, so they unit-test directly.
---
--- Deliberate improvements over the original (`autoload/db_ui/query.vim` +
--- `quote_query_value`):
---   * Placeholders are matched with `vim.regex` against the user's Vim-regex
---     `bind_param_pattern`, so a custom pattern (e.g. `\$\d\+`) Just Works
---     without rebuilding a vimscript regex by string concatenation.
---   * A placeholder is ignored when it sits inside a single-quoted SQL string
---     literal (`'... :id ...'`) or a comment (`-- :id`, `/* :id */`) --
---     consistently for BOTH detection and substitution. A small lexer carries
---     string and block-comment state across lines, so multi-line literals and
---     `/* ... */` blocks mask correctly. The original filtered such names out of
---     prompting but would still substitute them if the same name appeared
---     unquoted elsewhere, handled only single-line single-quoted strings, and
---     never skipped comments.
---   * The colon-prefix guard (so `value::text` casts are not seen as `:text`
---     placeholders) is a single "preceding char is not `:`" check rather than a
---     grouped capture, which keeps it pattern-agnostic.
---   * `quote()` escapes embedded single quotes (`O'Brien` -> `'O''Brien'`),
---     passes NULL and decimals/negatives through bare, and still respects an
---     already-quoted literal -- the original neither escaped quotes nor knew
---     about NULL or non-integer numbers.

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
  -- user pre-quoted, mirroring the original).
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
--- Per-line byte masks over `lines`: `masks[i][j]` (1-based) is true when byte
--- `j` of line `i` lies inside a single-quoted SQL string literal or a comment,
--- where a placeholder must NOT be detected or substituted. A small SQL lexer
--- carries string and `/* */` block-comment state ACROSS lines (both can span
--- newlines), while `--` line comments end at the line. `''` escape pairs inside
--- a string are kept inside it. Computed over the whole statement at once so a
--- string/comment opened on one line correctly masks later lines.
---@param lines string[]
---@return boolean[][]
local function build_masks(lines)
  local masks = {}
  local in_str = false -- inside a '...' literal (carries across lines)
  local in_block = false -- inside a /* ... */ comment (carries across lines)
  for li, line in ipairs(lines) do
    local mask = {}
    local in_line_comment = false -- after -- to end of THIS line only
    local i = 1
    local n = #line
    while i <= n do
      local c = line:sub(i, i)
      local c2 = line:sub(i + 1, i + 1)
      if in_line_comment then
        mask[i] = true
        i = i + 1
      elseif in_block then
        mask[i] = true
        if c == '*' and c2 == '/' then
          mask[i + 1] = true
          in_block = false
          i = i + 2
        else
          i = i + 1
        end
      elseif in_str then
        mask[i] = true
        if c == "'" then
          if c2 == "'" then
            mask[i + 1] = true -- doubled '' escape, still inside the string
            i = i + 2
          else
            in_str = false
            i = i + 1
          end
        else
          i = i + 1
        end
      elseif c == "'" then
        in_str = true
        mask[i] = true
        i = i + 1
      elseif c == '-' and c2 == '-' then
        in_line_comment = true
        mask[i] = true
        i = i + 1
      elseif c == '/' and c2 == '*' then
        in_block = true
        mask[i] = true
        mask[i + 1] = true
        i = i + 2
      else
        mask[i] = false
        i = i + 1
      end
    end
    masks[li] = mask
  end
  return masks
end

---@alias DadbodUI.BindOccurrence { name: string, s: integer, e: integer }

---@private
--- Build a per-line occurrence finder bound to `pattern`. The returned function
--- finds every placeholder in `line`, left to right, skipping any that sits in a
--- masked span (string literal or comment, per `mask`) or is immediately
--- preceded by `:` (so `::text` casts are not matched), and returns occurrences
--- with 0-based byte spans `[s, e)` so callers can rebuild the line. The compiled
--- regex is captured here (compiled once per detect/substitute call) -- its type
--- is left to inference because the upstream `vim.regex` class is `@nodoc` and
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
