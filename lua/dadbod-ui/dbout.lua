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
local paginator = require('dadbod-ui.paginator')
local schemas = require('dadbod-ui.schemas')
local spinner = require('dadbod-ui.spinner')
local spinners = require('dadbod-ui.spinners')
local utils = require('dadbod-ui.utils')

local M = {}

-- The drawer this module re-renders through; set on attach.
---@type DadbodUI.Drawer|nil
local attached = nil

-- True once the session autocmds / event subscriptions are registered.
local registered = false

-- Extmark namespace for the ghost text trailing the executed line in the query
-- buffer (cleared before each repaint). The result-buffer summary is rendered as
-- a `winbar`, not an extmark -- see render_result_summary for why.
local NS_QUERY = vim.api.nvim_create_namespace('dadbod_ui_query_time_query')

-- Where the next query was executed from, so the summary can trail ghost text on
-- that line. `pending_origin` is armed by the query controller right before it
-- dispatches and consumed synchronously by the DBExecutePre hook, which moves it
-- into `origins` keyed by the result file (so concurrent runs don't collide).
---@type DadbodUI.QueryOrigin|nil
local pending_origin = nil
---@type table<string, DadbodUI.QueryOrigin>
local origins = {}

-- Page state for a paginated query in flight, plumbed exactly like `pending_origin`
-- above: the query controller stashes it in `pending_page` synchronously before
-- executing, `DBExecutePre` moves it into `pending_by_file` keyed by the result
-- file (`_claim_pending`), and `_on_post` consumes it by that key. Keying on the
-- result file -- rather than assuming the next post is ours -- keeps the right
-- buffer tagged even if queries complete out of order.
---@type DadbodUI.PageState|nil
local pending_page = nil
---@type table<string, DadbodUI.PageState>
local pending_by_file = {}

--- Remember the buffer + line a query is being executed from. Called by the
--- query controller immediately before dispatch; the DBExecutePre hook claims it.
---@param origin DadbodUI.QueryOrigin
---@return nil
function M.arm_origin(origin)
  pending_origin = origin
end

--- Drop an armed origin that never reached execution (dispatch errored before
--- DBExecutePre fired), so it can't attach to an unrelated later run.
---@return nil
function M.disarm_origin()
  pending_origin = nil
end

--- The effective config: the attached drawer's, or the session singleton's when a
--- dbout buffer is touched before the drawer ever opened.
---@return DadbodUI.Config
local function current_config()
  if attached ~= nil then
    return attached.config
  end
  return require('dadbod-ui.state').get().config
end

--- The result-buffer spinner line for `frame` (the `dots12` braille glyph).
---@param frame string
---@return string
local function spinner_line(frame)
  return ' ' .. frame .. ' Executing query...'
end

--- Start animating the loading spinner in the result buffer for `output_file`.
--- No-op when the progress bar is disabled or the output buffer is not open yet.
--- The animation itself (frames, timing, timer hygiene) lives in `spinner`; we
--- only own how a frame is painted into the result buffer (which dadbod leaves
--- `nomodifiable`, so we flip it for the write; dadbod's reload discards these
--- buffer-only edits when the rows arrive).
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
  spinner.start(output_file, spinners.dots12, function(frame)
    if not vim.api.nvim_buf_is_valid(buf) then
      return spinner.stop(output_file)
    end
    vim.bo[buf].modifiable = true
    pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, { spinner_line(frame) })
  end)
end

--- Stop the spinner for `output_file` (dadbod has reloaded the rows by now).
---@param output_file string
---@return nil
function M._hide(output_file)
  spinner.stop(output_file)
end

-- Post-execute feedback (time + row count + pagination) ---------------------
--
-- When `query_time` is enabled we suppress dadbod's command-line echoes (see
-- bridge `quiet` + the scheduled clear in `_on_post`) and instead surface the
-- completion inline: a virtual line atop the `.dbout` buffer and/or ghost text
-- trailing the line the query ran from. dadbod hands us the exact timing for
-- free -- it stores `runtime` (float seconds) and `exit_status` on the result
-- buffer's `b:db` -- so we never run our own timer.

--- A line made only of table-drawing characters with at least one dash: the
--- column rule under a header (`---+---`, `+------+`).
---@param line string
---@return boolean
local function is_rule(line)
  return line:match('^[%s%-+|]+$') ~= nil and line:find('%-') ~= nil
end

--- The explicit row-count footer an engine prints, scanned from the bottom of
--- `lines` (it sits in the last few). postgres `(N rows)`, mysql `N rows in
--- set`, sqlserver `(N rows affected)`. nil when none of those match -- so the
--- caller can pass just the buffer tail here and only read the whole buffer for
--- the line-counting fallback. Pure, for unit tests.
---@param lines string[]
---@return integer|nil
function M._footer_rows(lines)
  for i = #lines, math.max(1, #lines - 4), -1 do
    local l = lines[i]
    local n = l:match('%((%d+)%s+rows?%)') -- postgres: (200 rows)
      or l:match('^%s*(%d+)%s+rows?%s+in%s+set') -- mysql:    200 rows in set
      or l:match('%((%d+)%s+rows?%s+affected%)') -- sqlserver: (200 rows affected)
    if n ~= nil then
      return tonumber(n)
    end
  end
  return nil
end

--- Best-effort row count for a result buffer's `lines`. Prefers the explicit
--- engine footer (`_footer_rows`); falls back to counting the data lines under
--- the first column rule (sqlite column mode, mysql batch). Returns nil when it
--- cannot tell -- the caller then omits the count rather than guessing.
---@param lines string[]
---@return integer|nil
function M._count_rows(lines)
  local footer = M._footer_rows(lines)
  if footer ~= nil then
    return footer
  end
  -- Fallback: count non-blank, non-rule data lines beneath the first rule.
  local rule_at
  for i, l in ipairs(lines) do
    if is_rule(l) then
      rule_at = i
      break
    end
  end
  if rule_at == nil then
    return nil
  end
  local count = 0
  for i = rule_at + 1, #lines do
    local l = lines[i]
    if l:match('^%s*$') then
      break -- a blank line closes the result block
    end
    if not is_rule(l) then
      count = count + 1
    end
  end
  return count > 0 and count or nil
end

--- The one-line summary string. `runtime` is dadbod's float seconds (nil omits
--- the duration); a non-zero/`nil`-status query reads as aborted; `rows` nil
--- omits the count. Pure, for unit tests.
---@param runtime number|nil
---@param exit_status integer|nil
---@param rows integer|nil
---@return string
function M._summary_text(runtime, exit_status, rows)
  local ok = exit_status == 0 or exit_status == nil
  local icon = ok and '✓' or '✗'
  local verb = ok and 'finished' or 'aborted'
  local text
  if runtime ~= nil then
    text = string.format('%s %s %s %.3fs', icon, verb, ok and 'in' or 'after', runtime)
  else
    text = string.format('%s %s', icon, verb)
  end
  if rows ~= nil then
    text = text .. string.format(' · %d row%s', rows, rows == 1 and '' or 's')
  end
  return text
end

--- Register a one-shot teardown: run `fn` the next time any of `events` fires on
--- `buf`, in a fresh per-buffer augroup (`name` + bufnr) so a repaint replaces
--- rather than stacks the cleanup. Used to drop the winbar / ghost text.
---@param buf integer
---@param name string  augroup name stem; the buffer number is appended
---@param events string|string[]
---@param fn fun(): nil
---@return nil
local function clear_on(buf, name, events, fn)
  local group = vim.api.nvim_create_augroup(name .. '_' .. buf, { clear = true })
  vim.api.nvim_create_autocmd(events, { group = group, buffer = buf, once = true, callback = fn })
end

--- Pin `winbar` (a fully-formed statusline-syntax string from `_winbar_text`) to
--- the top of the result window. We deliberately avoid a `virt_lines_above`
--- extmark on the first line: Neovim cannot draw a virtual line above a buffer's
--- first line (there is no screen row above it), so such an extmark exists but
--- never renders until an unrelated scroll happens to repaint the window. `winbar`
--- is the purpose-built window-top line -- it renders immediately and consumes no
--- buffer line, so line numbers / row counting / cell-nav stay intact.
---@param buf integer
---@param winbar string
---@return nil
local function render_result_summary(buf, winbar)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    pcall(vim.api.nvim_set_option_value, 'winbar', winbar, { win = win })
  end
  -- winbar is window-local; drop it when this result buffer leaves its window so a
  -- stale summary can't linger over whatever is shown there next (a later result
  -- repaints its own bar from _on_post).
  clear_on(buf, 'dadbod_ui_query_time_winbar', 'BufWinLeave', function()
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
      pcall(vim.api.nvim_set_option_value, 'winbar', '', { win = win })
    end
  end)
end

--- Trail the summary as ghost text at the end of the executed line in the query
--- buffer, and clear it on the next edit (so stale timing never lingers over a
--- query the user has since changed).
---@param origin DadbodUI.QueryOrigin
---@param text string
---@return nil
local function render_ghost(origin, text)
  if not vim.api.nvim_buf_is_valid(origin.bufnr) then
    return
  end
  local lnum = math.min(origin.lnum, vim.api.nvim_buf_line_count(origin.bufnr)) - 1
  if lnum < 0 then
    return
  end
  vim.api.nvim_buf_clear_namespace(origin.bufnr, NS_QUERY, 0, -1)
  pcall(vim.api.nvim_buf_set_extmark, origin.bufnr, NS_QUERY, lnum, 0, {
    virt_text = { { '  ' .. text, 'DadbodUIQueryTime' } },
    virt_text_pos = 'eol',
    hl_mode = 'combine',
  })
  clear_on(origin.bufnr, 'dadbod_ui_query_time', { 'TextChanged', 'TextChangedI', 'InsertEnter' }, function()
    pcall(vim.api.nvim_buf_clear_namespace, origin.bufnr, NS_QUERY, 0, -1)
  end)
end

--- Handle a finished async execution: tag the result buffer with any pending page
--- state, render the result winbar (time/row summary and/or pagination segments),
--- trail ghost text on the query line, swallow dadbod's trailing command-line
--- echo, and stop the loading spinner. The result buffer has been reloaded with
--- rows by the time this runs, so `b:db.runtime`/`exit_status` and the row count
--- are available.
---@param output_file string
---@return nil
function M._on_post(output_file)
  local origin = origins[output_file]
  origins[output_file] = nil
  local page = pending_by_file[output_file]
  pending_by_file[output_file] = nil

  local cfg = current_config().query_time
  local buf = utils.loaded_bufnr(output_file)

  -- Tag the result buffer so `[` / `]` can re-paginate, independent of query_time.
  if buf >= 0 and page ~= nil then
    vim.b[buf].dbui_page = page
  end

  -- The summary text needs query_time enabled; the winbar shows whenever there is
  -- something to put in it -- the summary and/or the pagination segments.
  local want_summary = cfg.enabled
  local want_winbar = (cfg.enabled and cfg.result_buffer) or page ~= nil
  if buf >= 0 and (want_summary or page ~= nil) then
    local db = vim.fn.getbufvar(buf, 'db')
    local runtime = type(db) == 'table' and tonumber(db.runtime) or nil
    local status = type(db) == 'table' and tonumber(db.exit_status) or 0
    -- Count rows when the summary wants them, or a paged result needs the range.
    local rows
    if status == 0 and ((want_summary and cfg.show_row_count) or page ~= nil) then
      -- The footer (the common case) lives in the last lines, so try it against
      -- just the tail; only the sqlite-column-mode fallback needs the full grid.
      local total = vim.api.nvim_buf_line_count(buf)
      rows = M._footer_rows(vim.api.nvim_buf_get_lines(buf, math.max(0, total - 5), total, false))
      if rows == nil then
        rows = M._count_rows(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      end
    end
    local summary = want_summary and M._summary_text(runtime, status, cfg.show_row_count and rows or nil) or nil
    if want_winbar then
      render_result_summary(buf, M._winbar_text(page, summary, rows))
    end
    if want_summary and cfg.query_buffer and origin ~= nil and summary ~= nil then
      render_ghost(origin, summary)
    end
  end
  -- dadbod's async job callback echoes `DB: Query ... finished in ...` on the
  -- command line the instant this hook returns (autoload/db.vim), and `:silent`
  -- can't reach that async echo. On the next tick, once it has fired, clear the
  -- command line and flush a repaint so the cleared line shows without a stray
  -- flash. (A message UI that captures echoes synchronously, e.g. Noice, needs
  -- its own route filter -- we can only clear the built-in command line.) Only
  -- relevant when query_time ran `:DB` quietly in the first place.
  if cfg.enabled then
    vim.schedule(function()
      pcall(vim.cmd, "echo ''")
      if buf >= 0 and vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim__redraw, { buf = buf, valid = false, flush = true })
      end
    end)
  end

  M._hide(output_file)
end

-- Pagination ----------------------------------------------------------------
--
-- A paginated query runs page 1 with a LIMIT/OFFSET clause (see
-- `dadbod-ui.paginator`); the query controller stashes the page state via
-- `set_pending`, `DBExecutePre` claims it onto the result file (`_claim_pending`),
-- and `_on_post` tags the freshly loaded result buffer with it (`b:dbui_page`) and
-- contributes its segments to the result winbar (see `_winbar_text`). `[` / `]`
-- then re-execute the stored SQL at an adjusted offset.

--- Receive the page state for the query about to execute (called by the query
--- controller, synchronously before execution). Claimed by `_claim_pending` on
--- the matching `DBExecutePre`.
---@param state DadbodUI.PageState
---@return nil
function M.set_pending(state)
  pending_page = state
end

--- Move any just-stashed page state onto `output_file` (the result file dadbod is
--- about to populate). Runs from DBExecutePre, which fires synchronously while the
--- `DB` command is still on the stack, so the stash can't be clobbered first.
---@param output_file string
---@return nil
function M._claim_pending(output_file)
  if pending_page ~= nil then
    pending_by_file[output_file] = pending_page
    pending_page = nil
  end
end

--- The pagination winbar segment for `state`: page number, row range and page
--- size. `rows` is this page's actual row count when known, so the last (partial)
--- page reports its true range; otherwise the full page span is assumed. nil when
--- `state` is nil (the result isn't paginated).
---@param state DadbodUI.PageState|nil
---@param rows integer|nil
---@return string|nil
function M._page_segment(state, rows)
  if state == nil then
    return nil
  end
  local first = (state.page - 1) * state.page_size + 1
  local last = rows ~= nil and (first + rows - 1) or state.page * state.page_size
  return string.format('Page %d · rows %d-%d · %d/page', state.page, first, last, state.page_size)
end

--- The page-nav hint segment (`[ prev  ] next`), or nil when `state` is nil.
---@param state DadbodUI.PageState|nil
---@return string|nil
function M._nav_segment(state)
  if state == nil then
    return nil
  end
  return '[ prev  ] next'
end

--- Wrap a plain segment `text` in a padded, highlighted winbar block. `%` in the
--- text is doubled so engine output can't inject statusline control codes; the
--- surrounding spaces give the block its tab-like padding.
---@param group string  highlight group (linked to a TabLine* group by default)
---@param text string
---@return string
local function winbar_block(group, text)
  return string.format('%%#%s# %s ', group, (text:gsub('%%', '%%%%')))
end

--- Compose the result-window winbar from its blocks, in display order: pagination
--- info (when paged), the time/row `summary`, then the page-nav hints. Each present
--- block is a padded, highlighted tab (pagination emphasized via DadbodUIWinbarPage,
--- the rest via DadbodUIWinbar), and the blocks are spread across the window width
--- with `%=` -- the fill (DadbodUIWinbarFill) paints the gaps -- so the first sits
--- hard left and the last hard right (justify-content: space-between). '' when there
--- is nothing to show. Adding a new piece of result feedback means adding a block.
---@param page DadbodUI.PageState|nil
---@param summary string|nil
---@param rows integer|nil
---@return string
function M._winbar_text(page, summary, rows)
  local blocks = {}
  local function add(group, text)
    if text ~= nil and text ~= '' then
      blocks[#blocks + 1] = winbar_block(group, text)
    end
  end
  add('DadbodUIWinbarPage', M._page_segment(page, rows))
  add('DadbodUIWinbar', summary)
  add('DadbodUIWinbar', M._nav_segment(page))
  if #blocks == 0 then
    return ''
  end
  return table.concat(blocks, '%#DadbodUIWinbarFill#%=')
end

--- Re-execute the current result's query at `delta` pages from the current page
--- (floored at page 1), through the tempfile path with a freshly paginated SQL.
--- The new page state is handed to `set_pending` so the resulting buffer is
--- tagged in turn. Notifies (rather than erroring) when the buffer carries no
--- pagination -- distinguishing an unsupported adapter from a query that simply
--- wasn't paginated (already limited / not a plain SELECT).
---@param delta integer
---@return nil
function M._step_page(delta)
  local notify = require('dadbod-ui.notifications')
  local state = vim.b.dbui_page
  if type(state) ~= 'table' then
    local db = vim.b.db
    local scheme = type(db) == 'table' and type(db.db_url) == 'string' and bridge.scheme_of(db.db_url) or nil
    if scheme ~= nil and not paginator.supports(scheme) then
      return notify.info(string.format('Pagination is not supported for the %s adapter.', scheme))
    end
    return notify.info('Pagination is not active for this result (already limited or not a plain SELECT).')
  end

  local new_page = math.max(1, state.page + delta)
  if new_page == state.page then
    return -- already on page 1 and stepping back
  end
  local sql = paginator.paginate(state.scheme, state.original_sql, new_page, state.page_size)
  if sql == nil then
    return notify.error('Unable to paginate this query.')
  end

  M.set_pending(vim.tbl_extend('force', state, { page = new_page }))
  -- No "Loading page N" notification: the result winbar carries the page state
  -- (page number + row range), so the feedback stays inline.
  bridge.execute_lines(vim.split(sql, '\n'), state.url)
end

--- `]` -- load the next page of results.
---@return nil
function M.next_page()
  M._step_page(1)
end

--- `[` -- load the previous page of results (floored at page 1).
---@return nil
function M.prev_page()
  M._step_page(-1)
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
    content = vim.fn.readfile(input, '', 1)[1] or ''
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
  -- Run quietly when the inline summary is on, so dadbod's `Running query...`
  -- echo doesn't reappear for the jump (the summary still renders via on_post).
  bridge.execute(url, query, current_config().query_time.enabled)
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
  local config_mod = require('dadbod-ui.config')
  local mappings = require('dadbod-ui.mappings')
  -- Keyed by the ids in `config.mappings.results`; the same data drives the help
  -- window. `cell_value` binds different keys per mode (`vic`/`ic`) via its
  -- explicit `binds`, so the handler ignores the mode argument.
  mappings.apply(config.mappings.results, config_mod.mapping_order.results, {
    jump_foreign = M.jump_to_foreign_table,
    cell_value = M.get_cell_value,
    yank_header = M.yank_header,
    toggle_layout = M.toggle_layout,
    next_page = M.next_page,
    prev_page = M.prev_page,
  }, { buffer = bufnr, silent = true, nowait = true })
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
    -- Claim the origin armed by the query controller (synchronous: this fires
    -- inside the `:DB` call, before any other execution can interleave).
    if pending_origin ~= nil then
      origins[info.output_file] = pending_origin
      pending_origin = nil
    end
    M._show(info.output_file)
    M._claim_pending(info.output_file)
  end, { group = group })
  bridge.on_post(function(info)
    M._on_post(info.output_file)
  end, { group = group })
end

return M
