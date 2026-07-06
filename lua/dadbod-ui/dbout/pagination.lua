-- Result pagination: [ / ] page stepping
--
-- A paginated query runs page 1 with a LIMIT/OFFSET clause (see
-- `dadbod-ui.paginator`); the query controller stashes the page state via
-- `set_pending` (the shared pending-context channel, in `init`), `DBExecutePre`
-- claims it onto the result file, and `_on_post` tags the freshly loaded result
-- buffer with it (`b:dbui_page`) and contributes its segments to the result
-- winbar (see `winbar._winbar_text`). `[` / `]` then re-execute the stored SQL at
-- an adjusted offset.

local bridge = require('dadbod-ui.bridge')
local paginator = require('dadbod-ui.paginator')
local ctx = require('dadbod-ui.dbout.ctx')

---@class DadbodUI.DboutPagination
---@field next_page fun()
---@field prev_page fun()
---@field _step_page fun(delta: integer)
local M = {}

---@private
-- The pending-context channel lives in `init` (constraint: `pending`/`by_file`
-- stay there). `_step_page` arms the next page through this injected reference so
-- pagination never requires `init` (which requires pagination -- that would be
-- circular). Set by `init` at load via `_set_pending_fn`.
---@type fun(state: DadbodUI.PageState)
local set_pending

-- Module-internal (called once by init at load).
--- Inject `init`'s public `set_pending` so `_step_page` can arm the next page's
--- state without requiring `init`.
---@param fn fun(state: DadbodUI.PageState)
---@return nil
function M._set_pending_fn(fn)
  set_pending = fn
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

  if delta > 0 and state.last then
    -- The current page returned fewer rows than a full page, so there is nothing
    -- after it: don't step forward into empty result pages.
    return notify.info('Already on the last page of results.')
  end
  local new_page = math.max(1, state.page + delta)
  if new_page == state.page then
    return -- already on page 1 and stepping back
  end
  local sql = paginator.paginate(state.scheme, state.original_sql, new_page, state.page_size)
  if sql == nil then
    return notify.error('Unable to paginate this query.')
  end

  -- Clear the stale `last` flag when stepping to a different page: it belongs to
  -- the page we are leaving, and `_on_post` recomputes it from the new page's row
  -- count. Left set, a failed row count on a non-last page would carry the old
  -- `last = true` forward and make `]` refuse to advance ever after.
  local next_state = vim.tbl_extend('force', state, { page = new_page })
  next_state.last = nil
  set_pending(next_state)
  -- No "Loading page N" notification: the result winbar carries the page state
  -- and shows a "running" segment for the load (painted from `_on_pre`), so the
  -- feedback stays inline and the command line stays quiet.
  bridge.execute_lines(vim.split(sql, '\n'), state.url, nil, ctx.current_config().results.layout == 'vertical')
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

return M
