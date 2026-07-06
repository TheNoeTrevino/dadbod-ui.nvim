-- Result summary + winbar compositing + export overlay
--
-- Everything that paints the `.dbout` result window's `winbar`: the pure summary
-- builders (`_footer_rows`/`_data_rows`/`_count_rows`/`_summary_text`), the
-- two-part compositing of the per-buffer query-time / pagination base and the
-- global export overlay, the pagination + nav segments, and the ghost text
-- trailing the executed query line. `init` drives these from `_on_pre`/`_on_post`.

local spinner = require('dadbod-ui.spinner')
local spinners = require('dadbod-ui.spinners')

---@class DadbodUI.DboutWinbar
--- result summary (pure halves, exported for unit tests)
---@field _footer_rows fun(lines: string[]): integer|nil
---@field _data_rows fun(lines: string[]): integer|nil
---@field _count_rows fun(lines: string[]): integer|nil
---@field _summary_text fun(runtime: number|nil, exit_status: integer|nil, rows: integer|nil): string
--- export progress overlay
---@field export_in_progress fun(): boolean
---@field export_start fun(buf: integer, fmt: string): integer
---@field export_stop fun(buf: integer, token: integer)
--- winbar segments
---@field _page_segment fun(state: DadbodUI.PageState|nil, rows: integer|nil): string|nil
---@field _nav_segment fun(state: DadbodUI.PageState|nil, prev_key: string, next_key: string): string|nil
---@field _nav_keys fun(config: DadbodUI.Config): { prev: string, next: string }
---@field _winbar_text fun(page: DadbodUI.PageState|nil, summary: string|nil, rows: integer|nil, nav_keys?: { prev: string, next: string }): string
--- compositing helpers used by init's _on_pre/_on_post coordinators
---@field set_base fun(buf: integer, base: string)
---@field arm_winbar_teardown fun(buf: integer)
---@field render_ghost fun(origin: DadbodUI.QueryOrigin, text: string)
---@field wants_winbar fun(cfg: DadbodUI.QueryTimeConfig, page: DadbodUI.PageState|nil): boolean
---@field RUNNING_SEGMENT string
local M = {}

---@private
-- Extmark namespace for the ghost text trailing the executed line in the query
-- buffer (cleared before each repaint). The result-buffer summary is rendered as
-- a `winbar`, not an extmark -- see set_winbar for why.
local NS_QUERY = vim.api.nvim_create_namespace('dadbod_ui_query_time_query')

-- Result winbar compositing. The query-time / pagination string is the per-buffer
-- "base"; the in-flight export overlays a right-aligned spinner segment on top.
-- They are kept apart so neither clobbers the other on repaint: query events
-- update the base, the export updates the overlay, and `render_winbar` re-composes
-- both.
---@private
---@type table<integer, string>
local winbar_base = {}
-- The single in-flight export (only one at a time -- the interactive entry point
-- refuses to start a second). GLOBAL, not per-buffer, and painted on every visible
-- `.dbout` window, so the spinner stays put as you keep querying. nil when idle.
---@private
---@type { fmt: string, frame: string, token: integer }|nil
local export_active = nil
---@private
-- Monotonic id handed back by `export_start`; `export_stop` only clears when its
-- token matches, so a stale stop can't wipe a newer export.
local export_token = 0

---@private
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

--- Count the non-blank, non-rule data lines beneath the first column rule -- the
--- footerless fallback (sqlite column mode, mysql batch). nil when there is no
--- rule or no data rows. Pure, for unit tests.
---@param lines string[]
---@return integer|nil
function M._data_rows(lines)
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

--- Best-effort row count for a result buffer's `lines`: the explicit engine
--- footer (`_footer_rows`) when present, else the line-counting fallback
--- (`_data_rows`). nil when neither can tell -- the caller then omits the count
--- rather than guessing. `_on_post` calls the two halves directly so it can scan
--- only the buffer tail for the footer before reading the whole grid.
---@param lines string[]
---@return integer|nil
function M._count_rows(lines)
  return M._footer_rows(lines) or M._data_rows(lines)
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

---@private
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

---@private
--- Pin `winbar` (a fully-formed statusline-syntax string from `_winbar_text`) to
--- the top of the result window. We deliberately avoid a `virt_lines_above`
--- extmark on the first line: Neovim cannot draw a virtual line above a buffer's
--- first line (there is no screen row above it), so such an extmark exists but
--- never renders until an unrelated scroll happens to repaint the window. `winbar`
--- is the purpose-built window-top line -- it renders immediately and consumes no
--- buffer line, so line numbers / row counting / cell-nav stay intact. Cheap
--- enough to call on every repaint (running -> finished); the BufWinLeave teardown
--- is armed once per buffer by `arm_winbar_teardown`.
---@param buf integer
---@param winbar string
---@return nil
local function set_winbar(buf, winbar)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    pcall(vim.api.nvim_set_option_value, 'winbar', winbar, { win = win })
  end
end

---@private
--- Wrap a plain segment `text` in a padded, highlighted winbar block. `%` in the
--- text is doubled so engine output can't inject statusline control codes; the
--- surrounding spaces give the block its tab-like padding.
---@param group string  highlight group (a distinct-background DadbodUIWinbar* group)
---@param text string
---@return string
local function winbar_block(group, text)
  return string.format('%%#%s# %s ', group, (text:gsub('%%', '%%%%')))
end

---@private
--- The right-aligned export-progress overlay: `%=` (push right) then a padded
--- "Exporting to <FMT> <spinner>" block. Global (there is only one export), so it
--- is the same on every result window. '' when no export is in flight.
---@return string
local function export_overlay()
  if export_active == nil then
    return ''
  end
  local label = 'Exporting to ' .. tostring(export_active.fmt):upper()
  local frame = export_active.frame or ''
  local text = frame == '' and label or (label .. ' ' .. frame)
  return '%=' .. winbar_block('DadbodUIWinbarExport', text)
end

---@private
--- Re-compose and apply `buf`'s result winbar from its two parts: the per-buffer
--- query-time / pagination base and the global export overlay. Called whenever
--- either changes (a query event, an export start/stop, or a spinner tick).
---@param buf integer
---@return nil
local function render_winbar(buf)
  set_winbar(buf, (winbar_base[buf] or '') .. export_overlay())
end

---@private
--- Repaint the export overlay on EVERY window currently showing a `.dbout` result,
--- so the spinner follows the user onto each new query result while the export
--- runs (and is removed everywhere when it finishes).
---@return nil
local function render_export_everywhere()
  -- Runs on every spinner tick, so build the (global, window-invariant) overlay
  -- once and set the winbar directly on each window we already hold -- no nested
  -- `win_findbuf` re-scan per buffer (as `render_winbar`/`set_winbar` would do).
  local overlay = export_overlay()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_is_valid(b) and vim.bo[b].filetype == 'dbout' then
      pcall(vim.api.nvim_set_option_value, 'winbar', (winbar_base[b] or '') .. overlay, { win = win })
    end
  end
end

-- Module-internal (driven by init's _on_pre/_on_post coordinators).
--- Set the query-time / pagination part of `buf`'s winbar and repaint (preserving
--- any export overlay). The single entry point the query hooks use.
---@param buf integer
---@param base string
---@return nil
function M.set_base(buf, base)
  winbar_base[buf] = base
  render_winbar(buf)
end

-- Module-internal (driven by init's _on_pre coordinator).
--- Arm the one-shot teardown that clears the window-local winbar when this result
--- buffer leaves its window, so a stale summary can't linger over whatever is
--- shown there next. Armed once per buffer (first paint from `_on_pre`); the
--- per-buffer augroup means a later result repaints its own bar undisturbed.
---@param buf integer
---@return nil
function M.arm_winbar_teardown(buf)
  clear_on(buf, 'dadbod_ui_query_time_winbar', 'BufWinLeave', function()
    winbar_base[buf] = nil
    local win = vim.fn.bufwinid(buf)
    if win ~= -1 then
      pcall(vim.api.nvim_set_option_value, 'winbar', '', { win = win })
    end
  end)
end

--- Whether an export is currently in flight. The interactive entry point checks
--- this to refuse starting a second one.
---@return boolean
function M.export_in_progress()
  return export_active ~= nil
end

--- Begin the (single) in-flight export: show an animated "Exporting to <FMT>"
--- segment on the right of every visible `.dbout` result winbar and return a token
--- to stop it with. The export itself runs off the main loop (see
--- `dadbod-ui.export`), so querying stays fully usable meanwhile and the spinner
--- follows onto each new result. `buf` is unused (the overlay is global); kept for
--- a symmetric call site. Pair with `export_stop`.
---@param buf integer
---@param fmt string  the target format id (shown upper-cased)
---@return integer token
function M.export_start(buf, fmt) -- luacheck: ignore buf
  export_token = export_token + 1
  export_active = { fmt = fmt, frame = '', token = export_token }
  -- A single global spinner (dots12, matching the in-buffer query loading
  -- spinner) repaints the overlay everywhere it should show.
  spinner.start('dbui_export', spinners.dots12, function(frame)
    if export_active ~= nil then
      export_active.frame = frame
      render_export_everywhere()
    end
  end)
  return export_active.token
end

--- End the in-flight export identified by `token`: stop the spinner and drop the
--- segment from every result winbar. Ignores a stale/mismatched token (and a
--- no-op when idle).
---@param buf integer
---@param token integer
---@return nil
function M.export_stop(buf, token) -- luacheck: ignore buf
  if export_active == nil or export_active.token ~= token then
    return
  end
  export_active = nil
  spinner.stop('dbui_export')
  render_export_everywhere()
end

-- Module-internal (driven by init's _on_post coordinator).
--- Trail the summary as ghost text at the end of the executed line in the query
--- buffer, and clear it on the next edit (so stale timing never lingers over a
--- query the user has since changed).
---@param origin DadbodUI.QueryOrigin
---@param text string
---@return nil
function M.render_ghost(origin, text)
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

-- Module-internal (read by init's _on_pre coordinator).
-- The summary segment shown while a query is in flight. Static (the buffer's own
-- spinner carries the animation) so the winbar itself never flickers; `_on_post`
-- swaps it for the finished summary in place, with the page/nav segments held
-- fixed throughout.
M.RUNNING_SEGMENT = '⏳ running query…'

-- Module-internal (read by init's _on_pre/_on_post coordinators).
--- Whether the result winbar should be shown for this execution: either the
--- time/row summary is enabled, or the result is paginated (the page/nav bar
--- shows regardless of `query_time`).
---@param cfg DadbodUI.QueryTimeConfig
---@param page DadbodUI.PageState|nil
---@return boolean
function M.wants_winbar(cfg, page)
  return (cfg.enabled and cfg.result_buffer) or page ~= nil
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

--- The page-nav hint segment: `← <prev>   <next> →`, where the keys are the
--- configured `[` / `]` mappings (so the bar tells you which keys page). nil when
--- `state` is nil (the result isn't paginated).
---@param state DadbodUI.PageState|nil
---@param prev_key string  the configured previous-page mapping
---@param next_key string  the configured next-page mapping
---@return string|nil
function M._nav_segment(state, prev_key, next_key)
  if state == nil then
    return nil
  end
  return string.format('← %s   %s →', prev_key, next_key)
end

--- The configured `[`/`]` page-step keys for the nav segment, formatted the same
--- way the help window shows them (aliases joined) via `mappings.keys_for_action`
--- -- the single source of truth for key display, so a rebound or aliased mapping
--- is reflected here rather than diverging. Returns `''` for an unbound action.
---@param config DadbodUI.Config
---@return { prev: string, next: string }
function M._nav_keys(config)
  local keys_for = require('dadbod-ui.mappings').keys_for_action
  local keys = config.results.keys
  return { prev = keys_for(keys, 'prev_page'), next = keys_for(keys, 'next_page') }
end

--- Compose the result-window winbar from its blocks, in display order: pagination
--- info (when paged), the time/row `summary`, then the page-nav arrows. Each present
--- block is a padded, distinctly-coloured tab (DadbodUIWinbarPage / DadbodUIWinbar /
--- DadbodUIWinbarNav), left-aligned and separated by a fill-coloured gap, with the
--- fill (DadbodUIWinbarFill) painting the rest of the bar. '' when there is nothing
--- to show. Adding a new piece of result feedback means adding a block here.
---@param page DadbodUI.PageState|nil
---@param summary string|nil
---@param rows integer|nil
---@param nav_keys? { prev: string, next: string }  page-step keys (defaults `[`/`]`)
---@return string
function M._winbar_text(page, summary, rows, nav_keys)
  nav_keys = nav_keys or { prev = '[', next = ']' }
  local blocks = {}
  local function add(group, text)
    if text ~= nil and text ~= '' then
      blocks[#blocks + 1] = winbar_block(group, text)
    end
  end
  add('DadbodUIWinbarPage', M._page_segment(page, rows))
  add('DadbodUIWinbar', summary)
  add('DadbodUIWinbarNav', M._nav_segment(page, nav_keys.prev, nav_keys.next))
  if #blocks == 0 then
    return ''
  end
  -- Left-aligned tabs with a fill-coloured gap between them, then fill to the
  -- right edge so the bar's tail matches the window rather than the last block.
  return table.concat(blocks, '%#DadbodUIWinbarFill# ') .. '%#DadbodUIWinbarFill#'
end

return M
