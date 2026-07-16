-- Folding + cell / foreign-key navigation
--
-- This module owns the whole `.dbout` lifecycle, wiring folding + maps from a
-- single `FileType dbout` autocmd in `attach`. The per-scheme dbout metadata
-- (`cell_line_number`/`cell_line_pattern`/`foreign_key_query`/…) lives on the
-- schema adapters in `dadbod-ui.schemas`. The foreign-key jump's introspection
-- lookup and the jump itself both go through `bridge` (the engine boundary);
-- this module never touches `:DB`/`db#` directly.

local bridge = require('dadbod-ui.bridge')
local bind_params = require('dadbod-ui.bind_params')
local notify = require('dadbod-ui.notifications')
local schemas = require('dadbod-ui.schemas')
local ctx = require('dadbod-ui.dbout.ctx')

---@class DadbodUI.DboutCells
---@field foldexpr_for fun(lines: table<integer, string>, lnum: integer): string|integer
---@field foldexpr fun(lnum: integer): string|integer
---@field cell_range fun(line: string, col0: integer): { from: integer, to: integer }
---@field display_span_to_byte_span fun(line: string, from_col: integer, to_col: integer): { from: integer, to: integer }
---@field parse_header fun(column_line: string, underline: string): string[]
---@field foreign_select fun(template: string, fschema: string, ftable: string, fcolumn: string, raw_value: string): string
---@field jump_to_foreign_table fun()
---@field get_cell_value fun()
---@field yank_header fun()
---@field toggle_layout fun()
local M = {}

--- Pure fold level for `lnum`, given a (sparse is fine) map of line number ->
--- text covering at least `lnum`..`lnum + 2`: mysql `+---` rows open a fold when
--- the matching border is two lines down; postgres & sqlserver open one when the
--- `----` underline is on the next line; blank lines close or continue a fold
--- depending on the following border.
---@param lines table<integer, string>
---@param lnum integer
---@return string|integer  a Vim foldexpr value ('>1' | 1 | 0)
function M.foldexpr_for(lines, lnum)
  ---@param n integer
  ---@return string
  local function line(n)
    return lines[n] or ''
  end
  local current = line(lnum)
  if not current:match('^%s*$') then
    -- mysql: a `+---` border with another `+---` two lines below starts a fold.
    if current:match('^%+%-%-%-') and line(lnum + 2):match('^%+%-%-%-') then
      return '>1'
    end
    -- postgres & sqlserver: a row whose next line is the `----` underline.
    if line(lnum + 1):match('^%-%-%-%-') then
      return '>1'
    end
    return 1
  end
  -- A blank line closes the fold only when it precedes the next result's
  -- underline (postgres & sqlserver); otherwise it stays in the current fold.
  if line(lnum + 2):match('^%-%-%-%-') then
    return 0
  end
  return 1
end

--- Buffer-backed foldexpr (set as the window's `foldexpr`). Reads only the three
--- lines `foldexpr_for` needs, so it stays O(1) per call on large result sets.
---@param lnum integer
---@return string|integer
function M.foldexpr(lnum)
  return M.foldexpr_for({
    [lnum] = vim.fn.getline(lnum),
    [lnum + 1] = vim.fn.getline(lnum + 1),
    [lnum + 2] = vim.fn.getline(lnum + 2),
  }, lnum)
end

--- The span `[from, to]` (0-based, inclusive) of the cell under `col0`, read off
--- the separator (column-underline) line `line`: the contiguous run of `-`
--- table-rule characters bracketing the column. Pure column arithmetic. The
--- separator line is pure ASCII, so its byte columns and display columns coincide
--- -- callers pass the cursor's DISPLAY column and treat
--- the result as a DISPLAY-column span, mapping it back to byte offsets on the
--- (possibly multibyte) header/value lines via `display_span_to_byte_span`.
---@param line string  the separator (column-underline) line
---@param col0 integer  0-based cursor display column
---@return { from: integer, to: integer }
function M.cell_range(line, col0)
  local DASH = '-'
  ---@param c integer
  ---@return string
  local function at(c)
    return line:sub(c + 1, c + 1)
  end
  local from = 0
  local c = col0
  while c >= 0 and at(c) == DASH do
    from = c
    c = c - 1
  end
  c = col0
  local to = 0
  while c <= #line and at(c) == DASH do
    to = c
    c = c + 1
  end
  return { from = from, to = to }
end

--- Map a DISPLAY-column span `[from_col, to_col]` (0-based, inclusive) -- as read
--- off the ASCII separator line by `cell_range` -- to the BYTE span `[from, to]`
--- (0-based, inclusive) on `line`, which may contain multibyte / double-width
--- characters. psql/mysql pad columns by DISPLAY width, so a naive byte slice of
--- a data/header line with the separator's byte offsets drifts once an earlier
--- cell holds a wide character; walking `line` char-by-char and accumulating
--- display width keeps every cell's boundary aligned. Aligned output never lets a
--- character straddle a column boundary, so a character is in the span iff it
--- starts within it. Returns an empty span (`to < from`) when nothing falls in
--- range (e.g. the span sits past the end of a short line).
---@param line string  the header/value line to slice (byte offsets)
---@param from_col integer  0-based display column of the cell's left edge
---@param to_col integer  0-based display column of the cell's right edge
---@return { from: integer, to: integer }
function M.display_span_to_byte_span(line, from_col, to_col)
  local from, to
  local byte = 0 -- 0-based byte offset of the current character
  local col = 0 -- 0-based display column where the current character starts
  local n = vim.fn.strchars(line)
  for i = 0, n - 1 do
    if col > to_col then
      break -- every remaining character starts past the span; nothing left to set
    end
    local ch = vim.fn.strcharpart(line, i, 1)
    if from == nil and col >= from_col then
      from = byte
    end
    to = byte + #ch - 1
    byte = byte + #ch
    col = col + vim.fn.strdisplaywidth(ch)
  end
  from = from or #line -- span starts past the line end -> empty slice
  to = to or from - 1
  return { from = from, to = to }
end

--- Parse the header row into column names, splitting the `column_line` wherever
--- the `underline` separator breaks the rule of `-`s (column gaps / `+` joints).
--- Empty columns produced by leading/trailing separators (mysql's `+...+`
--- borders) are dropped.
---@param column_line string  the header-names line
---@param underline string  the `-`/`+` rule line
---@return string[]
function M.parse_header(column_line, underline)
  local DASH = '-'
  ---@param i integer
  ---@return string
  local function ul(i)
    return underline:sub(i + 1, i + 1)
  end
  local columns = {}
  local from = 0
  local last = #underline
  local i = 0
  while i <= last do
    if ul(i) ~= DASH or i == last then
      local to = i - 1
      if to >= from then
        local name = vim.trim(column_line:sub(from + 1, to + 1))
        if name ~= '' then
          columns[#columns + 1] = name
        end
      end
      from = i + 1
    end
    i = i + 1
  end
  return columns
end

--- Build the foreign-key `SELECT` from the adapter template and the resolved
--- foreign (schema, table, column) plus the cell value (quoted through the shared
--- `bind_params.quote`). Pure; `string.format` performs the substitution.
---@param template string  the adapter's select_foreign_key_query
---@param fschema string
---@param ftable string
---@param fcolumn string
---@param raw_value string  the (unquoted) cell value
---@return string
function M.foreign_select(template, fschema, ftable, fcolumn, raw_value)
  return string.format(template, fschema, ftable, fcolumn, bind_params.quote(raw_value))
end

---@private
--- The separator (column-underline) line number for the result block under the
--- cursor: scan up from the cursor for a line matching the adapter's
--- `cell_line_pattern`, falling back to its fixed `cell_line_number`.
---@param scheme_info DadbodUI.SchemaAdapter
---@return integer
local function cell_line_number(scheme_info)
  local fallback = scheme_info.cell_line_number or 1
  local pattern = scheme_info.cell_line_pattern
  local line = vim.fn.line('.')
  if pattern == nil then
    return fallback
  end
  while line > fallback do
    if vim.fn.match(vim.fn.getline(line), pattern) > -1 then
      return line
    end
    line = line - 1
  end
  return fallback
end

---@private
--- The dbout buffer's connection url + adapter metadata, or nil (with a notified
--- error) when the buffer has no `b:db` or its scheme is unsupported for `action`.
---@param action string  user-facing verb for the error message
---@return string?, DadbodUI.SchemaAdapter?
local function resolve_scheme(action)
  local db = vim.b.db
  if type(db) ~= 'table' or type(db.db_url) ~= 'string' then
    return notify.error('Not a query result buffer.')
  end
  local url = db.db_url
  local scheme = bridge.scheme_of(url)
  local scheme_info = schemas.get(scheme, ctx.current_config())
  if vim.tbl_isempty(scheme_info) then
    notify.error(string.format('%s not supported for %s scheme.', action, scheme))
    return nil, nil
  end
  return url, scheme_info
end

---@private
--- The display-column span of the cell under the cursor, read off the ASCII
--- separator line at `sep_line_nr`. The cursor's byte column on `data_line` is
--- converted to a display column so the span lines up on multibyte rows. Shared
--- by the FK jump and the cell-value selection.
---@param sep_line_nr integer
---@param data_line string  the line the cursor is on
---@return { from: integer, to: integer }
local function cursor_cell_span(sep_line_nr, data_line)
  local cursor_col = vim.fn.strdisplaywidth(data_line:sub(1, vim.fn.col('.') - 1))
  return M.cell_range(vim.fn.getline(sep_line_nr), cursor_col)
end

---@private
-- Whether a foreign-key lookup is already in flight: the async round-trip is
-- short, but a second <C-]> before it lands must not race a duplicate lookup.
local fk_jump_pending = false

--- Jump from the foreign-key cell under the cursor to the row(s) it references.
--- Resolves the foreign table with a NON-BLOCKING introspection query
--- (`bridge.run_many`), then runs the resulting `SELECT` -- both through
--- `bridge`. Everything the callback needs (cell context, config) is captured
--- before dispatch, so a focus change during the round-trip cannot misread it.
---@return nil
function M.jump_to_foreign_table()
  local url, scheme_info = resolve_scheme('Foreign key jump')
  if url == nil or scheme_info == nil then
    return
  end
  if scheme_info.foreign_key_query == nil then
    return notify.error(string.format('Foreign key jump not supported for %s scheme.', bridge.scheme_of(url)))
  end
  if fk_jump_pending then
    return
  end

  local sep_line_nr = cell_line_number(scheme_info)
  local data_line = vim.fn.getline('.')
  local header_line = vim.fn.getline(sep_line_nr - 1)
  local span = cursor_cell_span(sep_line_nr, data_line)
  local hrange = M.display_span_to_byte_span(header_line, span.from, span.to)
  local vrange = M.display_span_to_byte_span(data_line, span.from, span.to)
  local field_name = vim.trim(header_line:sub(hrange.from + 1, hrange.to + 1))
  local field_value = vim.trim(data_line:sub(vrange.from + 1, vrange.to + 1))

  local fk_query = (scheme_info.foreign_key_query:gsub('{col_name}', function()
    return field_name
  end))
  -- An adapter with a foreign_key_query always carries a parser + select template.
  local parser = assert(scheme_info.parse_results)
  local template = assert(scheme_info.select_foreign_key_query)
  local config = ctx.current_config()

  fk_jump_pending = true
  bridge.run_many({ schemas.command_spec(url, scheme_info, fk_query) }, function(results)
    fk_jump_pending = false
    local result = parser(schemas.result_lines(results[1]), 3)
    if #result == 0 then
      return notify.error('No valid foreign key found.')
    end
    -- result rows are { foreign_table_name, foreign_column_name, foreign_table_schema }
    local row = result[1]
    local query = M.foreign_select(template, row[3], row[1], row[2], field_value)
    -- Run quietly when the inline summary is on, so dadbod's `Running query...`
    -- echo doesn't reappear for the jump (the summary still renders via on_post).
    bridge.execute(url, query, config.results.query_time.enabled, config.results.layout == 'vertical')
  end)
end

--- Visually select the cell value under the cursor (the `vic` text object / the
--- operator-pending `ic`). Computes the cell span off the separator line, trims
--- surrounding padding, and leaves a charwise visual selection over the trimmed
--- value -- so `vic` selects and `{op}ic` operates without a register-clobbering
--- `gvy`.
---@return nil
function M.get_cell_value()
  local url, scheme_info = resolve_scheme('Yanking cell value')
  if url == nil or scheme_info == nil then
    return
  end
  local sep_line_nr = cell_line_number(scheme_info)
  local data_line = vim.fn.getline('.')
  local span = cursor_cell_span(sep_line_nr, data_line)
  local range = M.display_span_to_byte_span(data_line, span.from, span.to)
  local value = data_line:sub(range.from + 1, range.to + 1)
  local from = range.from + #(value:match('^%s*') or '')
  local to = range.to - #(value:match('%s*$') or '')
  if to < from then
    return
  end
  local lnum = vim.fn.line('.')
  vim.api.nvim_win_set_cursor(0, { lnum, from })
  vim.cmd('normal! v')
  -- Under `set selection=exclusive` the char at the end cursor is left out of the
  -- selection, shorting the cell by one; step past the value's last CHARACTER --
  -- one byte is not enough when it is multibyte, since a mid-character column
  -- keeps the cursor on it (query.lua's get_lines forces inclusive for the same
  -- reason). Clamp + pcall so a cell ending at end-of-line can't raise.
  local end_col = to
  if vim.o.selection == 'exclusive' then
    end_col = vim.fn.byteidx(data_line, vim.fn.charidx(data_line, to) + 1)
    if end_col < 0 then
      end_col = #data_line
    end
  end
  if not pcall(vim.api.nvim_win_set_cursor, 0, { lnum, end_col }) then
    vim.api.nvim_win_set_cursor(0, { lnum, to })
  end
end

--- Yank the header row of the result block under the cursor as a CSV string into
--- the active register, using `setreg` so it honors `"x` register prefixes
--- without touching the visual selection.
---@return nil
function M.yank_header()
  local url, scheme_info = resolve_scheme('Yanking headers')
  if url == nil or scheme_info == nil then
    return
  end
  local sep_line_nr = cell_line_number(scheme_info)
  local columns = M.parse_header(vim.fn.getline(sep_line_nr - 1), vim.fn.getline(sep_line_nr))
  vim.fn.setreg(vim.v.register, table.concat(columns, ', '))
end

--- Toggle the result layout between row and expanded/vertical form (`<Leader>R`),
--- maintaining the `b:db_ui_expanded_layout` interop contract var. Re-runs the
--- query through dadbod's own reload (`R`) -- collapsing restores the original
--- input, expanding appends the adapter's `layout_flag` to a temp copy.
---@return nil
function M.toggle_layout()
  local db = vim.b.db
  if type(db) ~= 'table' or type(db.db_url) ~= 'string' then
    return notify.error('Not a query result buffer.')
  end
  local scheme = bridge.scheme_of(db.db_url)
  local scheme_info = schemas.get(scheme, ctx.current_config())
  if scheme_info.layout_flag == nil then
    return notify.error(string.format('Toggling layout not supported for %s scheme.', scheme))
  end

  local expanded = vim.b.db_ui_expanded_layout
  if expanded == 1 or expanded == true then
    vim.b.db_ui_expanded_layout = 0
    vim.cmd('normal R') -- dadbod's reload mapping, with the original input
    return
  end

  local content = table.concat(vim.fn.readfile(db.input), '\n')
  content = (content:gsub('%s*;?%s*$', '')) .. ' ' .. scheme_info.layout_flag
  local tmp = vim.fn.tempname()
  vim.fn.writefile(vim.split(content, '\n'), tmp)
  local old_input = db.input
  -- b:db is dadbod's query dict; reassign the whole table so the swapped input
  -- is visible to dadbod's reload, then restore it afterwards. The reload can
  -- raise (e.g. "query already running for this tab"); pcall it so a failure
  -- still restores the original input -- otherwise b:db.input stays pointed at
  -- the flag-appended temp file and every retry appends the flag again.
  db.input = tmp
  vim.b.db = db
  local ok, err = pcall(vim.cmd, 'normal R')
  db.input = old_input
  vim.b.db = db
  if not ok then
    return notify.error('Toggling layout failed: ' .. tostring(err))
  end
  vim.b.db_ui_expanded_layout = 1
end

return M
