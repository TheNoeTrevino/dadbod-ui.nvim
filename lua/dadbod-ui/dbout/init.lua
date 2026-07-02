-- Result buffers: in-buffer loading spinner + result list
--
-- Drives the `.dbout` result buffers that dadbod produces. dadbod opens the
-- (empty) output buffer in a preview window and fires `*DBExecutePre`, runs the
-- query asynchronously, reloads the file with rows, then fires `*DBExecutePost`.
-- We hook those events to animate a loading spinner *inside* the output buffer
-- while the query runs (replaced by the rows on completion), and we record each
-- executed result under the drawer's `Query results` section.
--
-- This deviates from the original on the loading symbol only: vim-dadbod-ui
-- shows a floating progress window, whereas we animate a braille `dots12`
-- spinner in the buffer itself. Both are gated by `disable_progress_bar`.
--
-- This module is the wiring / coordinator: it owns the per-execution pending
-- context and the DB event hooks (`_on_pre`/`_on_post`), and delegates the result
-- winbar / summary to `dadbod-ui.dbout.winbar`, pagination to
-- `dadbod-ui.dbout.pagination`, and folding + cell navigation to
-- `dadbod-ui.dbout.cells`. Their surfaces are re-exported here so
-- `require('dadbod-ui.dbout').<name>` stays the single public entry point.

local bridge = require('dadbod-ui.bridge')
local spinner = require('dadbod-ui.spinner')
local spinners = require('dadbod-ui.spinners')
local utils = require('dadbod-ui.utils')

local ctx = require('dadbod-ui.dbout.ctx')
local winbar = require('dadbod-ui.dbout.winbar')
local pagination = require('dadbod-ui.dbout.pagination')
local cells = require('dadbod-ui.dbout.cells')

---@class DadbodUI.DboutModule
--- lifecycle / wiring
---@field attach fun(drawer: DadbodUI.Drawer)
---@field setup_buffer fun(bufnr: integer)
--- execution context (armed by the query controller, claimed by the DB hooks)
---@field arm_origin fun(origin: DadbodUI.QueryOrigin)
---@field disarm_origin fun()
---@field set_pending fun(state: DadbodUI.PageState)
---@field _on_pre fun(output_file: string)  DBExecutePre half, exported for the bridge subscription
---@field _on_post fun(output_file: string)  DBExecutePost half, exported for the bridge subscription
---@field _show fun(output_file: string)  loading-spinner half of _on_pre; test seam
---@field _hide fun(output_file: string)  loading-spinner half of _on_post; test seam
--- result summary (pure halves, exported for unit tests) -- re-exported from winbar
---@field _footer_rows fun(lines: string[]): integer|nil
---@field _data_rows fun(lines: string[]): integer|nil
---@field _count_rows fun(lines: string[]): integer|nil
---@field _summary_text fun(runtime: number|nil, exit_status: integer|nil, rows: integer|nil): string
--- export progress overlay -- re-exported from winbar
---@field export_in_progress fun(): boolean
---@field export_start fun(buf: integer, fmt: string): integer
---@field export_stop fun(buf: integer, token: integer)
--- pagination -- re-exported from pagination
---@field next_page fun()
---@field prev_page fun()
---@field _step_page fun(delta: integer)
--- winbar segments -- re-exported from winbar
---@field _page_segment fun(state: DadbodUI.PageState|nil, rows: integer|nil): string|nil
---@field _nav_segment fun(state: DadbodUI.PageState|nil, prev_key: string, next_key: string): string|nil
---@field _nav_keys fun(config: DadbodUI.Config): { prev: string, next: string }
---@field _winbar_text fun(page: DadbodUI.PageState|nil, summary: string|nil, rows: integer|nil, nav_keys?: { prev: string, next: string }): string
--- drawer Query results section
---@field save_dbout fun(file: string)
---@field sort_dbout fun(a: string, b: string): boolean
--- folding + cell/foreign-key navigation -- re-exported from cells
---@field foldexpr_for fun(lines: table<integer, string>, lnum: integer): string|integer
---@field foldexpr fun(lnum: integer): string|integer
---@field cell_range fun(line: string, col0: integer): { from: integer, to: integer }
---@field parse_header fun(column_line: string, underline: string): string[]
---@field foreign_select fun(template: string, fschema: string, ftable: string, fcolumn: string, raw_value: string): string
---@field jump_to_foreign_table fun()
---@field get_cell_value fun()
---@field yank_header fun()
---@field toggle_layout fun()

---@type DadbodUI.DboutModule
---@diagnostic disable-next-line: missing-fields
local M = {}

---@private
-- True once the session autocmds / event subscriptions are registered.
local registered = false

-- One per-execution "pending context", armed by the query controller right
-- before it dispatches and claimed synchronously by the DBExecutePre hook, which
-- moves it into `by_file` keyed by the result file (so concurrent runs don't
-- collide -- the right buffer stays tagged even if queries finish out of order).
-- `origin` trails ghost text on the executed line; `page` drives the winbar's
-- pagination + `[`/`]` re-paging. Both are optional and armed independently -- a
-- plain run arms only `origin`, a page step only `page`, an initial paginated
-- query arms both, so arming merges rather than replaces.
---@class DadbodUI.PendingContext
---@field origin? DadbodUI.QueryOrigin
---@field page? DadbodUI.PageState
---@private
---@type DadbodUI.PendingContext|nil
local pending = nil
---@private
---@type table<string, DadbodUI.PendingContext>
local by_file = {}

---@private
--- Merge `value` into the pending context under `field`, creating it on first arm.
---@param field 'origin'|'page'
---@param value DadbodUI.QueryOrigin|DadbodUI.PageState
---@return nil
local function arm(field, value)
  pending = pending or {}
  pending[field] = value
end

---@private
--- Claim the pending context onto `output_file` and clear it. Runs from
--- DBExecutePre, synchronously while the `DB` command is still on the stack, so
--- the context can't be clobbered before it is keyed to its result file.
---@param output_file string
---@return nil
local function claim(output_file)
  if pending ~= nil then
    by_file[output_file] = pending
    pending = nil
  end
end

--- Remember the buffer + line a query is being executed from, so the summary can
--- trail ghost text there. Called by the query controller immediately before
--- dispatch; the DBExecutePre hook claims it.
---@param origin DadbodUI.QueryOrigin
---@return nil
function M.arm_origin(origin)
  arm('origin', origin)
end

--- Drop the pending context when a dispatch errored before DBExecutePre claimed
--- it, so nothing armed for the failed run leaks into an unrelated later one.
---@return nil
function M.disarm_origin()
  pending = nil
end

--- Receive the page state for the query about to execute (called by the query
--- controller / `_step_page`, synchronously before execution). Merged into the
--- pending context and claimed on the matching `DBExecutePre`.
---@param state DadbodUI.PageState
---@return nil
function M.set_pending(state)
  arm('page', state)
end

-- `_step_page` (in the pagination submodule) arms the next page through this same
-- channel; hand it the public `set_pending` so it never has to require this module.
pagination._set_pending_fn(M.set_pending)

---@private
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
  if ctx.attached == nil or ctx.attached.config.disable_progress_bar then
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
-- buffer's `b:db` -- so we never run our own timer. The winbar / summary / ghost
-- text builders live in `dadbod-ui.dbout.winbar`; these hooks coordinate them.

--- Handle the start of an async execution: claim the armed origin and pending
--- page onto this result file, start the in-buffer loading spinner, and paint the
--- result winbar in its "running" state. Painting it now (same synchronous tick
--- as dadbod opening the output window, before any redraw) keeps the bar present
--- continuously through the load -- otherwise it would blink out between the
--- previous result's bar and the finished one. The page/nav segments are known
--- up front, so only the middle summary changes when `_on_post` lands the rows.
---@param output_file string
---@return nil
function M._on_pre(output_file)
  -- Claim whatever the query controller armed (synchronous: this fires inside the
  -- `:DB` call, before any other execution can interleave).
  claim(output_file)
  M._show(output_file)

  local config = ctx.current_config()
  local cfg = config.query_time
  local page = (by_file[output_file] or {}).page
  if not winbar.wants_winbar(cfg, page) then
    return
  end
  local buf = utils.loaded_bufnr(output_file)
  if buf >= 0 then
    local summary = cfg.enabled and winbar.RUNNING_SEGMENT or nil
    winbar.set_base(buf, winbar._winbar_text(page, summary, nil, winbar._nav_keys(config)))
    winbar.arm_winbar_teardown(buf)
  end
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
  local ctx_pending = by_file[output_file] or {}
  by_file[output_file] = nil
  local origin = ctx_pending.origin
  local page = ctx_pending.page

  local config = ctx.current_config()
  local cfg = config.query_time
  local buf = utils.loaded_bufnr(output_file)

  -- Tag the result buffer so `[` / `]` can re-paginate, independent of query_time.
  if buf >= 0 and page ~= nil then
    vim.b[buf].dbui_page = page
  end

  -- dadbod fills `b:db.runtime`/`exit_status` (seconds / status, as strings) on the
  -- reloaded result buffer before this hook runs; read them once here for both the
  -- runtime record below and the summary further down.
  local db = buf >= 0 and vim.fn.getbufvar(buf, 'db') or nil
  local runtime = type(db) == 'table' and tonumber(db.runtime) or nil

  -- Record the runtime on the drawer's query controller so `get_last_query_info`
  -- (hence `:DBUILastQueryInfo` and the dbout branch of `statusline`) can report
  -- it, independent of the `query_time` UI config.
  if ctx.attached ~= nil and runtime ~= nil then
    ctx.attached:query().last_query_time = string.format('%.3f', runtime)
  end

  -- The summary text needs query_time enabled; the winbar shows whenever there is
  -- something to put in it -- the summary and/or the pagination segments.
  local want_summary = cfg.enabled
  local want_winbar = winbar.wants_winbar(cfg, page)
  if buf >= 0 and (want_summary or page ~= nil) then
    local status = type(db) == 'table' and tonumber(db.exit_status) or 0
    -- Count rows when the summary wants them, or a paged result needs the range.
    local rows
    if status == 0 and ((want_summary and cfg.show_row_count) or page ~= nil) then
      -- The footer (the common case) lives in the last lines, so try it against
      -- just the tail; only the sqlite-column-mode fallback needs the full grid.
      local total = vim.api.nvim_buf_line_count(buf)
      rows = winbar._footer_rows(vim.api.nvim_buf_get_lines(buf, math.max(0, total - 5), total, false))
      if rows == nil then
        -- Footer missed in the tail; the whole-buffer footer scan would miss too,
        -- so go straight to the line-counting fallback.
        rows = winbar._data_rows(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      end
    end
    -- A page that came back with fewer rows than a full page is the last one:
    -- record it so `]` can refuse to advance into empty result pages (a partial
    -- or empty page means there is nothing after it). Left unset when the row
    -- count is unknown, so the guard only fires when we are certain.
    if page ~= nil and rows ~= nil then
      vim.b[buf].dbui_page = vim.tbl_extend('force', page, { last = rows < page.page_size })
    end
    local summary = want_summary and winbar._summary_text(runtime, status, cfg.show_row_count and rows or nil) or nil
    if want_winbar then
      winbar.set_base(buf, winbar._winbar_text(page, summary, rows, winbar._nav_keys(config)))
    end
    if want_summary and cfg.query_buffer and origin ~= nil and summary ~= nil then
      winbar.render_ghost(origin, summary)
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

  -- Fire `on_execute_query_post`: the result has landed, so a hook can read/persist
  -- it (the "save results elsewhere" use case). `rows()` reads lazily -- from the
  -- loaded result buffer when available, else the output file -- so a hook that
  -- only wants the status/timing pays nothing. `query` is the executed statement
  -- (the result's input file). Isolated: a throwing hook never disturbs the result.
  -- Guarded on the hook's presence: `hooks.run` no-ops when nobody is listening
  -- (the default), but only after the `query` input-file read below -- so skip that
  -- I/O entirely unless a config hook OR a runtime `api.on` listener is registered.
  if require('dadbod-ui.hooks').has(config, 'on_execute_query_post') then
    local status = type(db) == 'table' and tonumber(db.exit_status) or 0
    local input = bridge.dbout_input(output_file)
    require('dadbod-ui.hooks').run(config, 'on_execute_query_post', {
      output_file = output_file,
      rows = function()
        if buf >= 0 then
          return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        end
        return vim.fn.filereadable(output_file) == 1 and vim.fn.readfile(output_file) or {}
      end,
      query = (input ~= nil and vim.fn.filereadable(input) == 1) and vim.fn.readfile(input) or {},
      runtime = runtime,
      exit_status = status,
    })
  end

  M._hide(output_file)
end

--- Record an executed result file under the drawer's `Query results` section and
--- re-render. The preview content is the first line of the query input (the
--- statement that produced it), truncated. Port of `s:dbui.save_dbout`.
---@param file string  the .dbout result file path
---@return nil
function M.save_dbout(file)
  if ctx.attached == nil then
    return
  end
  local list = ctx.attached.instance.dbout_list
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
  ctx.attached:render()
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
  if ctx.attached ~= nil and ctx.attached.config.dbout_list_sort == 'desc' then
    return na > nb
  end
  return na < nb
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

  local config = ctx.current_config()
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
    export = function()
      require('dadbod-ui.export').export_interactive(bufnr)
    end,
    -- The async job is tied to THIS output buffer's `b:db` (dadbod also binds its
    -- own `<C-c>` here), so `cancel_query` -- which cancels `nvim_get_current_buf()`
    -- -- targets the query that produced these results. Reuses the full hook path.
    cancel = function()
      require('dadbod-ui').cancel_query()
    end,
  }, { buffer = bufnr, silent = true, nowait = true })
end

--- Register the session-wide autocmds and bridge subscriptions once: `.dbout`
--- filetype, per-buffer folding + navigation setup, result recording on read, and
--- the loading spinner on the async execute events. Idempotent; remembers
--- `drawer` for re-rendering.
---@param drawer DadbodUI.Drawer
---@return nil
function M.attach(drawer)
  ctx.attached = drawer
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
    M._on_pre(info.output_file)
  end, { group = group })
  bridge.on_post(function(info)
    M._on_post(info.output_file)
  end, { group = group })
end

-- Re-export the submodule surfaces so `require('dadbod-ui.dbout').<name>` stays the
-- single public entry point (the foldexpr string, specs, and call sites all reach
-- these through this module).
M._footer_rows = winbar._footer_rows
M._data_rows = winbar._data_rows
M._count_rows = winbar._count_rows
M._summary_text = winbar._summary_text
M.export_in_progress = winbar.export_in_progress
M.export_start = winbar.export_start
M.export_stop = winbar.export_stop
M._page_segment = winbar._page_segment
M._nav_segment = winbar._nav_segment
M._nav_keys = winbar._nav_keys
M._winbar_text = winbar._winbar_text

M.next_page = pagination.next_page
M.prev_page = pagination.prev_page
M._step_page = pagination._step_page

M.foldexpr_for = cells.foldexpr_for
M.foldexpr = cells.foldexpr
M.cell_range = cells.cell_range
M.parse_header = cells.parse_header
M.foreign_select = cells.foreign_select
M.jump_to_foreign_table = cells.jump_to_foreign_table
M.get_cell_value = cells.get_cell_value
M.yank_header = cells.yank_header
M.toggle_layout = cells.toggle_layout

return M
