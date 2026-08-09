-- The SQL quoting/comment lexer (per-byte masks)
--
-- The single state machine that knows what is "not code" in a SQL statement.
-- Extracted from dadbod-ui.bind_params so every consumer shares one lexer:
-- bind-parameter detection must NOT match inside these spans, and any future
-- SQL-reading feature gets the same masking rules for free.
--
-- Four quoting/commenting forms are tracked so a stray colon or apostrophe
-- inside one cannot corrupt the state of the rest of the statement:
--   * `'...'` single-quoted string literals (`''` escape pairs stay inside),
--   * `"..."` double-quoted identifiers (`""` escape pairs stay inside),
--   * `$tag$...$tag$` dollar-quoted bodies (bare `$$` too) -- quotes inside a
--     Postgres function body do not flip string state,
--   * `--` line comments and `/* ... */` block comments.
-- String, double-quote, dollar-quote and block-comment state all carry ACROSS
-- lines; `--` comments end at their line. Computed over the whole statement at
-- once so a span opened on one line correctly masks later lines.

---@class DadbodUI.SqlMasksModule
---@field build fun(lines: string[]): boolean[][]

---@type DadbodUI.SqlMasksModule
---@diagnostic disable-next-line: missing-fields
local M = {}

---@private
--- Detect a dollar-quote opener (Postgres `$tag$` / bare `$$`) at byte `i` of
--- `line`. The tag is empty or a Postgres identifier (leading letter/underscore,
--- then word chars) -- crucially NOT digits-only, so a `$1`-style bind parameter
--- is never mistaken for a dollar quote. Returns the full delimiter text (e.g.
--- `$$` or `$tag$`) or nil when there is no opener here.
---@param line string
---@param i integer
---@return string|nil
local function dollar_open(line, i)
  return line:match('^%$%$', i) or line:match('^%$[%a_][%w_]*%$', i)
end

--- Per-line byte masks over `lines`: `masks[i][j]` (1-based) is true when byte
--- `j` of line `i` lies inside a string/identifier/comment/dollar span --
--- i.e. anywhere SQL-reading code must not match.
---@param lines string[]
---@return boolean[][]
function M.build(lines)
  local masks = {}
  local in_str = false -- inside a '...' literal (carries across lines)
  local in_dquote = false -- inside a "..." quoted identifier (carries across lines)
  local in_block = false -- inside a /* ... */ comment (carries across lines)
  local dollar_tag = nil -- the open $tag$ delimiter while inside a dollar-quoted body
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
      elseif dollar_tag then
        -- Inside a $tag$ body: mask until the matching close delimiter, which is
        -- the literal opening tag repeated.
        if line:sub(i, i + #dollar_tag - 1) == dollar_tag then
          for k = i, i + #dollar_tag - 1 do
            mask[k] = true
          end
          i = i + #dollar_tag
          dollar_tag = nil
        else
          mask[i] = true
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
      elseif in_dquote then
        mask[i] = true
        if c == '"' then
          if c2 == '"' then
            mask[i + 1] = true -- doubled "" escape, still inside the identifier
            i = i + 2
          else
            in_dquote = false
            i = i + 1
          end
        else
          i = i + 1
        end
      elseif c == "'" then
        in_str = true
        mask[i] = true
        i = i + 1
      elseif c == '"' then
        in_dquote = true
        mask[i] = true
        i = i + 1
      elseif c == '$' then
        local tag = dollar_open(line, i)
        if tag ~= nil then
          dollar_tag = tag
          for k = i, i + #tag - 1 do
            mask[k] = true
          end
          i = i + #tag
        else
          mask[i] = false
          i = i + 1
        end
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

return M
