---@mod dadbod-ui.dbout  Result buffers: in-buffer loading spinner + result list
---
--- Drives the `.dbout` result buffers that dadbod produces. dadbod opens the
--- (empty) output buffer in a preview window and fires `*DBExecutePre`, runs the
--- query asynchronously, reloads the file with rows, then fires `*DBExecutePost`.
--- We hook those events to animate a loading spinner *inside* the output buffer
--- while the query runs (replaced by the rows on completion), and we record each
--- executed result under the drawer's `Query results` section.
---
--- This deviates from the original on the loading symbol only: vim-dadbod-ui
--- shows a floating progress window, whereas we animate a braille `dots12`
--- spinner in the buffer itself. Both are gated by `disable_progress_bar`.

local bridge = require('dadbod-ui.bridge')
local bind_params = require('dadbod-ui.bind_params')
local schemas = require('dadbod-ui.schemas')
local utils = require('dadbod-ui.utils')

local M = {}

-- The braille `dots12` spinner: 56 frames cycled every 80ms.
local SPINNER = {
  interval = 80,
  frames = {
    '⢀⠀', '⡀⠀', '⠄⠀', '⢂⠀', '⡂⠀', '⠅⠀', '⢃⠀', '⡃⠀',
    '⠍⠀', '⢋⠀', '⡋⠀', '⠍⠁', '⢋⠁', '⡋⠁', '⠍⠉', '⠋⠉',
    '⠋⠉', '⠉⠙', '⠉⠙', '⠉⠩', '⠈⢙', '⠈⡙', '⢈⠩', '⡀⢙',
    '⠄⡙', '⢂⠩', '⡂⢘', '⠅⡘', '⢃⠨', '⡃⢐', '⠍⡐', '⢋⠠',
    '⡋⢀', '⠍⡁', '⢋⠁', '⡋⠁', '⠍⠉', '⠋⠉', '⠋⠉', '⠉⠙',
    '⠉⠙', '⠉⠩', '⠈⢙', '⠈⡙', '⠈⠩', '⠀⢙', '⠀⡙', '⠀⠩',
    '⠀⢘', '⠀⡘', '⠀⠨', '⠀⢐', '⠀⡐', '⠀⠠', '⠀⢀', '⠀⡀',
  },
}

-- output_file -> { timer = uv_timer, buf = integer, frame = integer }
local spinners = {}

-- The drawer this module re-renders through; set on attach.
---@type DadbodUI.Drawer|nil
local attached = nil

-- True once the session autocmds / event subscriptions are registered.
local registered = false

--- The spinner line for `frame`.
---@param frame integer
---@return string
local function spinner_line(frame)
  return ' ' .. SPINNER.frames[frame] .. ' Executing query...'
end

--- Stop and forget the spinner for `output_file`, if any.
---@param output_file string
---@return nil
local function stop_spinner(output_file)
  local s = spinners[output_file]
  if s == nil then
    return
  end
  spinners[output_file] = nil
  pcall(function()
    s.timer:stop()
    if not s.timer:is_closing() then
      s.timer:close()
    end
  end)
end

--- Write the current frame into the output buffer (which dadbod leaves
--- `nomodifiable`, so we flip it for the write). dadbod's reload discards these
--- buffer-only edits when the rows arrive.
---@param output_file string
---@return nil
local function paint(output_file)
  local s = spinners[output_file]
  if s == nil then
    return
  end
  if not vim.api.nvim_buf_is_valid(s.buf) then
    return stop_spinner(output_file)
  end
  vim.bo[s.buf].modifiable = true
  pcall(vim.api.nvim_buf_set_lines, s.buf, 0, -1, false, { spinner_line(s.frame) })
  s.frame = s.frame % #SPINNER.frames + 1
end

--- Start animating the loading spinner in the result buffer for `output_file`.
--- No-op when the progress bar is disabled or the output buffer is not open yet.
---@param output_file string
---@return nil
function M._show(output_file)
  if attached == nil or attached.config.disable_progress_bar then
    return
  end
  local buf = utils.loaded_bufnr(output_file)
  if buf < 0 then
    return
  end
  stop_spinner(output_file)
  local timer = vim.uv.new_timer()
  if timer == nil then
    return
  end
  spinners[output_file] = { timer = timer, buf = buf, frame = 1 }
  paint(output_file)
  timer:start(
    SPINNER.interval,
    SPINNER.interval,
    vim.schedule_wrap(function()
      paint(output_file)
    end)
  )
end

--- Stop the spinner for `output_file` (dadbod has reloaded the rows by now).
---@param output_file string
---@return nil
function M._hide(output_file)
  stop_spinner(output_file)
end

--- Record an executed result file under the drawer's `Query results` section and
--- re-render. The preview content is the first line of the query input (the
--- statement that produced it), truncated. Port of `s:dbui.save_dbout`.
---@param file string  the .dbout result file path
---@return nil
function M.save_dbout(file)
  if attached == nil then
    return
  end
  local list = attached.instance.dbout_list
  if list[file] ~= nil and list[file] ~= '' then
    return
  end
  local content = ''
  local input = bridge.dbout_input(file)
  if input ~= nil and vim.fn.filereadable(input) == 1 then
    content = (vim.fn.readfile(input, '', 1)[1]) or ''
    if #content > 30 then
      content = content:sub(1, 31) .. '...'
    end
  end
  list[file] = content
  attached:render()
end

--- Comparator for result files in the `Query results` section: numeric by
--- basename, ascending or descending per `dbout_list_sort`. Port of
--- `s:sort_dbout`.
---@param a string
---@param b string
---@return boolean
function M.sort_dbout(a, b)
  -- basename without its last extension (`:t:r`); the `(.)%.` guard keeps a
  -- leading-dot name intact, matching Vim's `:r` (which never strips a dotfile).
  local na = tonumber((vim.fs.basename(a):gsub('(.)%.[^.]*$', '%1'))) or 0
  local nb = tonumber((vim.fs.basename(b):gsub('(.)%.[^.]*$', '%1'))) or 0
  if attached ~= nil and attached.config.dbout_list_sort == 'desc' then
    return na > nb
  end
  return na < nb
end

-- Folding + cell/foreign-key navigation -------------------------------------
--
-- We diverge from the original's `ftplugin/dbout.vim` + `db_ui#dbout#*`: instead
-- of a VimL ftplugin we own the whole `.dbout` lifecycle here, wiring folding +
-- maps from a single `FileType dbout` autocmd in `attach`. The per-scheme dbout
-- metadata (`cell_line_number`/`cell_line_pattern`/`foreign_key_query`/…) lives
-- on the schema adapters in `dadbod-ui.schemas`. The foreign-key jump's
-- introspection lookup and the jump itself both go through `bridge` (the engine
-- boundary); this module never touches `:DB`/`db#` directly.

--- The effective config: the attached drawer's, or the session singleton's when a
--- dbout buffer is touched before the drawer ever opened.
---@return DadbodUI.Config
local function current_config()
  if attached ~= nil then
    return attached.config
  end
  return require('dadbod-ui.state').get().config
end

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
  local scheme_info = schemas.get(scheme, current_config())
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
  bridge.execute(url, query)
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
  local scheme_info = schemas.get(scheme, current_config())
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

--- Configure a `.dbout` result buffer: Lua expr-folding by result block (first
--- fold opened), and the navigation maps unless disabled. Wired from the
--- `FileType dbout` autocmd. Folding is always set; only the maps honor
--- `disable_mappings` / `disable_mappings_dbout`.
---@param bufnr integer
---@return nil
function M.setup_buffer(bufnr)
  vim.wo.foldmethod = 'expr'
  vim.wo.foldexpr = "v:lua.require'dadbod-ui.dbout'.foldexpr(v:lnum)"
  pcall(vim.cmd, 'silent! normal! zo') -- open the first fold on load

  local config = current_config()
  if config.disable_mappings or config.disable_mappings_dbout then
    return
  end
  ---@param mode string|string[]
  ---@param lhs string
  ---@param fn fun()
  local function map(mode, lhs, fn)
    vim.keymap.set(mode, lhs, fn, { buffer = bufnr, silent = true, nowait = true })
  end
  map('n', '<C-]>', M.jump_to_foreign_table)
  map('n', 'vic', M.get_cell_value)
  map('o', 'ic', M.get_cell_value)
  map('n', 'yh', M.yank_header)
  map('n', '<Leader>R', M.toggle_layout)
end

--- Register the session-wide autocmds and bridge subscriptions once: `.dbout`
--- filetype, per-buffer folding + navigation setup, result recording on read, and
--- the loading spinner on the async execute events. Idempotent; remembers
--- `drawer` for re-rendering.
---@param drawer DadbodUI.Drawer
---@return nil
function M.attach(drawer)
  attached = drawer
  if registered then
    return
  end
  registered = true
  local group = vim.api.nvim_create_augroup('dadbod_ui_dbout', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufRead', 'BufNewFile' }, {
    group = group,
    pattern = '*.dbout',
    callback = function()
      vim.bo.filetype = 'dbout'
    end,
  })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'dbout',
    callback = function(args)
      M.setup_buffer(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd('BufReadPost', {
    group = group,
    pattern = '*.dbout',
    callback = function(args)
      M.save_dbout(args.match)
    end,
  })
  bridge.on_pre(function(info)
    M._show(info.output_file)
  end, { group = group })
  bridge.on_post(function(info)
    M._hide(info.output_file)
  end, { group = group })
end

return M
