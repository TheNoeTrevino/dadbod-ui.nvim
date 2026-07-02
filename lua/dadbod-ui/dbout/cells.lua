---@mod dadbod-ui.dbout.cells  Folding + cell / foreign-key navigation
---
--- We diverge from the original's `ftplugin/dbout.vim` + `db_ui#dbout#*`: instead
--- of a VimL ftplugin we own the whole `.dbout` lifecycle here, wiring folding +
--- maps from a single `FileType dbout` autocmd in `attach`. The per-scheme dbout
--- metadata (`cell_line_number`/`cell_line_pattern`/`foreign_key_query`/…) lives
--- on the schema adapters in `dadbod-ui.schemas`. The foreign-key jump's
--- introspection lookup and the jump itself both go through `bridge` (the engine
--- boundary); this module never touches `:DB`/`db#` directly.

local bridge = require('dadbod-ui.bridge')
local bind_params = require('dadbod-ui.bind_params')
local schemas = require('dadbod-ui.schemas')
local ctx = require('dadbod-ui.dbout.ctx')

---@class DadbodUI.DboutCells
---@field foldexpr_for fun(lines: table<integer, string>, lnum: integer): string|integer
---@field foldexpr fun(lnum: integer): string|integer
---@field cell_range fun(line: string, col0: integer): { from: integer, to: integer }
---@field parse_header fun(column_line: string, underline: string): string[]
---@field foreign_select fun(template: string, fschema: string, ftable: string, fcolumn: string, raw_value: string): string
---@field jump_to_foreign_table fun()
---@field get_cell_value fun()
---@field yank_header fun()
---@field toggle_layout fun()
local M = {}

--- Pure fold level for `lnum`, given a (sparse is fine) map of line number ->
--- text covering at least `lnum`..`lnum + 2`. Port of `db_ui#dbout#foldexpr`:
--- mysql `+---` rows open a fold when the matching border is two lines down;
--- postgres & sqlserver open one when the `----` underline is on the next line;
--- blank lines close or continue a fold depending on the following border.
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

--- The byte-column span `[from, to]` (0-based, inclusive) of the cell under
--- `col0` (0-based), read off the separator line `line`: the contiguous run of
--- `-` table-rule characters bracketing the column. Pure column arithmetic, port
--- of `s:get_cell_range` (non-virtual path). Both column header and value lines
--- are sliced by this same span since result columns are monospace-aligned.
---@param line string  the separator (column-underline) line
---@param col0 integer  0-based cursor byte column
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

--- Parse the header row into column names, splitting the `column_line` wherever
--- the `underline` separator breaks the rule of `-`s (column gaps / `+` joints).
--- Port of `s:yank_header`'s scan, improved: we drop empty columns produced by
--- leading/trailing separators (mysql's `+...+` borders) instead of the original's
--- `[0:-1]` whole-string artifact.
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
--- `bind_params.quote`). Pure; `string.format` keeps the substitution free of the
--- original's hand-built command string. Port of the `printf` in
--- `jump_to_foreign_table`.
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
--- `cell_line_pattern`, falling back to its fixed `cell_line_number`. Port of
--- `s:get_cell_line_number`.
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
  local notify = require('dadbod-ui.notifications')
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

--- Jump from the foreign-key cell under the cursor to the row(s) it references.
--- Resolves the foreign table with a synchronous introspection query and runs the
--- resulting `SELECT`, both through `bridge`. Port of
--- `db_ui#dbout#jump_to_foreign_table`.
---@return nil
function M.jump_to_foreign_table()
  local notify = require('dadbod-ui.notifications')
  local url, scheme_info = resolve_scheme('Foreign key jump')
  if url == nil or scheme_info == nil then
    return
  end
  if scheme_info.foreign_key_query == nil then
    return notify.error(string.format('Foreign key jump not supported for %s scheme.', bridge.scheme_of(url)))
  end

  local sep_line_nr = cell_line_number(scheme_info)
  local range = M.cell_range(vim.fn.getline(sep_line_nr), vim.fn.col('.') - 1)
  local field_name = vim.trim(vim.fn.getline(sep_line_nr - 1):sub(range.from + 1, range.to + 1))
  local field_value = vim.trim(vim.fn.getline('.'):sub(range.from + 1, range.to + 1))

  local fk_query = (scheme_info.foreign_key_query:gsub('{col_name}', function()
    return field_name
  end))
  -- An adapter with a foreign_key_query always carries a parser + select template.
  local parser = assert(scheme_info.parse_virtual_results or scheme_info.parse_results)
  local template = assert(scheme_info.select_foreign_key_query)
  local result = parser(schemas.query(url, scheme_info, fk_query), 3)
  if #result == 0 then
    return notify.error('No valid foreign key found.')
  end

  -- result rows are { foreign_table_name, foreign_column_name, foreign_table_schema }
  local row = result[1]
  local query = M.foreign_select(template, row[3], row[1], row[2], field_value)
  -- Run quietly when the inline summary is on, so dadbod's `Running query...`
  -- echo doesn't reappear for the jump (the summary still renders via on_post).
  local config = ctx.current_config()
  bridge.execute(url, query, config.query_time.enabled, config.result_layout == 'vertical')
end

--- Visually select the cell value under the cursor (the `vic` text object / the
--- operator-pending `ic`). Computes the cell span off the separator line, trims
--- surrounding padding, and leaves a charwise visual selection over the trimmed
--- value -- so `vic` selects and `{op}ic` operates without a register-clobbering
--- `gvy`. Port of `db_ui#dbout#get_cell_value`.
---@return nil
function M.get_cell_value()
  local url, scheme_info = resolve_scheme('Yanking cell value')
  if url == nil or scheme_info == nil then
    return
  end
  local sep_line_nr = cell_line_number(scheme_info)
  local range = M.cell_range(vim.fn.getline(sep_line_nr), vim.fn.col('.') - 1)
  local value = vim.fn.getline('.'):sub(range.from + 1, range.to + 1)
  local from = range.from + #(value:match('^%s*') or '')
  local to = range.to - #(value:match('%s*$') or '')
  if to < from then
    return
  end
  local lnum = vim.fn.line('.')
  vim.api.nvim_win_set_cursor(0, { lnum, from })
  vim.cmd('normal! v')
  vim.api.nvim_win_set_cursor(0, { lnum, to })
end

--- Yank the header row of the result block under the cursor as a CSV string into
--- the active register. Port of `db_ui#dbout#yank_header`, using `setreg` so it
--- honors `"x` register prefixes without touching the visual selection.
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
--- input, expanding appends the adapter's `layout_flag` to a temp copy. Port of
--- `db_ui#dbout#toggle_layout`.
---@return nil
function M.toggle_layout()
  local notify = require('dadbod-ui.notifications')
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
  -- is visible to dadbod's reload, then restore it afterwards.
  db.input = tmp
  vim.b.db = db
  vim.cmd('normal R')
  db.input = old_input
  vim.b.db = db
  vim.b.db_ui_expanded_layout = 1
end

return M
