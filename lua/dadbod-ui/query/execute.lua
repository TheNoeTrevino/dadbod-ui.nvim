-- The execution flow for query buffers
--
-- A method mixin merged into `DadbodUI.Query` by `query/init.lua`: reading the
-- buffer/selection, the bind-parameter resolve/prompt/persist flow, dispatch
-- through the bridge (with page-1 auto-pagination), and the execute duals --
-- explain and export -- plus cancel and the bind-parameter editor.

local bridge = require('dadbod-ui.bridge')
local bind_params = require('dadbod-ui.bind_params')
local notify = require('dadbod-ui.notifications')
local hooks = require('dadbod-ui.hooks')
local dbout = require('dadbod-ui.dbout')
local paginator = require('dadbod-ui.paginator')
local export = require('dadbod-ui.export')
local explain = require('dadbod-ui.explain')
local explain_run = require('dadbod-ui.explain.run')

--- A last-mile SQL rewrite hook for `execute_query`/`execute_selection`. Receives
--- the runnable SQL (a single string, after bind-param substitution) and returns
--- the SQL to run instead -- e.g. wrapping the query in EXPLAIN. Returning nil
--- runs the query unchanged.
---@alias DadbodUI.SqlTransform fun(sql: string): string|nil

---@private
--- Reduce a raw `vim.cmd` error from dadbod to its user-facing message: strip
--- the Lua/`nvim_exec2`/`Vim(echoerr):` wrappers, leaving e.g. `DB: Query
--- already running for this tab`.
---@param err any
---@return string
local function clean_execute_error(err)
  local s = tostring(err)
  return s:match('Vim%b():(.+)$') or s:match('DB:.+$') or s
end

---@private
--- The buffer's stored bind params (`b:dbui_bind_params`) as a table. Reads
--- defensively: the drawer's rename passthrough copies the raw buffer var, which
--- is `''` (not a dict) when the source buffer never had any -- so anything
--- non-table is normalized to an empty table.
---@param bufnr integer
---@return DadbodUI.BindParams
local function stored_params(bufnr)
  local raw = vim.b[bufnr].dbui_bind_params
  return type(raw) == 'table' and raw or {}
end

---@private
--- Prompt sequentially for every name in `names` not already in `known`,
--- accumulating into a fresh copy. `on_done` receives the merged values, or nil
--- the moment the user aborts any prompt -- so a cancelled run neither executes
--- nor persists a partial set. Prompts go through the injectable `input` so specs
--- can drive them.
---@param input DadbodUI.UiInput
---@param names string[]  placeholder names in query order
---@param known DadbodUI.BindParams  already-answered values
---@param on_done fun(values: DadbodUI.BindParams|nil)
---@return nil
local function prompt_params(input, names, known, on_done)
  local values = vim.deepcopy(known)
  local pending = vim
    .iter(names)
    :filter(function(name)
      return values[name] == nil
    end)
    :totable()
  local i = 0
  local function step()
    i = i + 1
    if i > #pending then
      return on_done(values)
    end
    local name = pending[i]
    input({ prompt = string.format('Enter value for bind parameter %s -> ', name) }, function(val)
      if val == nil then
        return on_done(nil) -- aborted: stop, persist nothing
      end
      values[name] = val
      step()
    end)
  end
  step()
end

---@private
--- Resolve bind-param values before falling back to prompting. Fires the
--- `resolve_bind_params` config hook (if any) with the placeholder `names` and the
--- already-`known` values; any string values it returns for those names are merged
--- on top of `known` (the hook is authoritative for the keys it answers), so
--- `prompt_params` only prompts for what is still missing. A missing / throwing
--- hook is a clean no-op -- the flow degrades to plain prompting. Lets users source
--- values from env / a vault / a fixed table instead of typing them.
---@param config DadbodUI.Config
---@param input DadbodUI.UiInput
---@param names string[]  placeholder names in query order
---@param known DadbodUI.BindParams  already-answered values
---@param on_done fun(values: DadbodUI.BindParams|nil)
---@return nil
local function resolve_params(config, input, names, known, on_done)
  local resolved = hooks.call(config, 'resolve_bind_params', names, known)
  if type(resolved) == 'table' then
    -- Copy so we never mutate the buffer's stored `b:dbui_bind_params` table, and
    -- only pull string values for the actual placeholders (ignore stray keys).
    known = vim.tbl_extend('keep', {}, known)
    for _, name in ipairs(names) do
      if type(resolved[name]) == 'string' then
        known[name] = resolved[name]
      end
    end
  end
  prompt_params(input, names, known, on_done)
end

---@class DadbodUI.Query
local Query = {}

--- Resolve the bind parameters in `lines` and hand the runnable SQL to
--- `on_ready`: the shared front half of `execute_query` and its explain/export
--- duals. Placeholders are detected against `bind_param_pattern`; with none,
--- `on_ready(lines, false)` runs synchronously. Otherwise values are resolved
--- (config hook first, then prompting -- see `resolve_params`), the full set is
--- persisted in `b:dbui_bind_params`, and `on_ready(substituted, true)` runs.
--- Cancelling any prompt aborts with a "Query not <verb>." notification and
--- never calls `on_ready`. The buffer is captured up front and the persist is
--- guarded on it still existing -- the async prompt may resolve after it was
--- wiped -- but `on_ready` runs regardless: the callers target their captured
--- connection, not the current buffer.
---@param lines string[]
---@param verb string  'executed'|'explained'|'exported', for the cancel notice
---@param on_ready fun(final_lines: string[], substituted: boolean)
---@return nil
function Query:with_resolved_sql(lines, verb, on_ready)
  local pattern = self.config.query.bind_param_pattern
  local names = bind_params.detect(lines, pattern)
  if #names == 0 then
    return on_ready(lines, false)
  end
  -- Capture the buffer now: an async prompt may resolve after focus has moved.
  local bufnr = vim.api.nvim_get_current_buf()
  resolve_params(self.config, self.input, names, stored_params(bufnr), function(values)
    if values == nil then
      return notify.info(string.format('Bind parameters cancelled. Query not %s.', verb))
    end
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.b[bufnr].dbui_bind_params = values
    end
    on_ready(bind_params.substitute(lines, values, pattern), true)
  end)
end

--- The buffer (or, in visual mode, the selection) as a line list. Reads the
--- selection with `getregion` instead of `gvy`, so it never runs a normal-mode
--- yank or touches the unnamed register. `exclusive = false` reproduces the
--- original `selection=inclusive` yank regardless of the user's `&selection`.
---
--- The selection endpoints come from one of two places depending on how the
--- caller's mapping is wired, because the `'<`/`'>` marks are only updated when
--- visual mode is LEFT:
---   * Still in visual mode -- a Lua-callback / `<Cmd>` mapping runs without
---     leaving it, so the marks are stale (or unset `[0,0,0,0]` on a first-ever
---     selection, which made `getregion` raise `E475`). Use the live `v`/`.`
---     positions and the current `mode()` instead.
---   * Back in normal mode -- a `:<C-u>`-style mapping already committed the
---     selection, so the `'<`/`'>` marks + `visualmode()` are authoritative.
--- Either way we operate on the user's actual current selection.
---@param is_visual? boolean
---@return string[]
function Query:get_lines(is_visual)
  if not is_visual then
    return vim.api.nvim_buf_get_lines(0, 0, -1, false)
  end
  local mode = vim.fn.mode()
  local from, to, regtype
  if mode == 'v' or mode == 'V' or mode == '\22' then
    from, to, regtype = vim.fn.getpos('v'), vim.fn.getpos('.'), mode
  else
    from, to, regtype = vim.fn.getpos("'<"), vim.fn.getpos("'>"), vim.fn.visualmode()
  end
  if regtype == '' then
    regtype = 'v' -- no recorded visual mode yet; default to charwise
  end
  return vim.fn.getregion(from, to, { type = regtype, exclusive = false })
end

--- Run already-substituted `lines` through the engine via a temp file (see
--- `bridge.execute_lines`). `entry` is captured before prompting so execution
--- targets the right connection even if focus moved while an async prompt was open.
---@param lines string[]
---@param entry DadbodUI.ConnectionEntry
---@param quiet? boolean  suppress dadbod's command-line echo (inline feedback path)
---@return nil
function Query:run_from_file(lines, entry, quiet)
  bridge.execute_lines(lines, entry.conn, quiet, self.config.results.layout == 'vertical')
end

--- Dispatch `lines` for `entry`, auto-paginating as page 1 when the adapter and
--- query support it (plain SELECT, no existing paging clause): the LIMIT/OFFSET
--- query runs through the tempfile path and the page state is handed to
--- `dadbod-ui.dbout` so the result buffer can step pages with `[` / `]`. Otherwise
--- the query runs unmodified -- a whole-buffer run still takes the fast `%DB`
--- path, a selection/substituted run goes through the tempfile. `quiet` suppresses
--- dadbod's echo so the inline time/row feedback can take its place.
---@param lines string[]
---@param entry DadbodUI.ConnectionEntry
---@param whole_buffer boolean  true for an unmodified whole-buffer run (eligible for %DB)
---@param quiet? boolean
---@return nil
function Query:dispatch(lines, entry, whole_buffer, quiet)
  local sql = table.concat(lines, '\n')
  local page_size = self.config.results.page_size
  local paginated = paginator.paginate(entry.scheme, sql, 1, page_size)
  if paginated ~= nil then
    dbout.set_pending({
      original_sql = sql,
      page = 1,
      page_size = page_size,
      scheme = entry.scheme,
      url = entry.conn,
    })
    return self:run_from_file(vim.split(paginated, '\n'), entry, quiet)
  end
  if whole_buffer then
    return bridge.execute_buffer(quiet, self.config.results.layout == 'vertical')
  end
  self:run_from_file(lines, entry, quiet)
end

--- Execute the current query buffer (or visual selection) through dadbod. The
--- whole buffer with no placeholders runs directly via `%DB` (a `%` range is
--- always valid, so no marks are involved). A visual selection is read with
--- `vim.fn.getregion` -- the live selection, independent of the `'<`/`'>` marks --
--- and run from a temp file. This deliberately avoids dadbod's mark-based
--- `'<,'>DB`: a Lua-callback / `<Cmd>` mapping fires while still in visual mode,
--- so the marks aren't committed yet and `'<,'>DB` raised `E20: Mark not set`
--- (and the old getregion-over-marks read raised `E475`). Reading the selection
--- text and feeding it to dadbod sidesteps marks entirely, so execution works
--- regardless of how the user wired the mapping.
---
--- When `bind_param_pattern` matches we prompt for any not-yet-known parameters,
--- persist the full set in `b:dbui_bind_params`, substitute the quoted values, and
--- run the rewritten SQL from a temp file. Cancelling a prompt aborts without
--- executing or persisting. Dadbod errors (e.g. a query already running for the
--- tab) surface as a notification rather than a raw stack trace.
---
--- `transform` is an optional last-mile rewrite hook: it receives the runnable SQL
--- (a single string, AFTER any bind params are substituted) and returns the SQL to
--- run instead -- e.g. wrapping the query in EXPLAIN. This is the sanctioned
--- MUTATION point, distinct from the observer-only `on_execute_query` event.
--- Returning nil (or omitting `transform`) runs the buffer unchanged (whole-buffer
--- runs keep dadbod's `%DB` fast path).
---@param is_visual? boolean
---@param transform? DadbodUI.SqlTransform
---@return nil
function Query:execute_query(is_visual, transform)
  local lines = self:get_lines(is_visual)

  -- Inline post-execute feedback (time + row count) replaces dadbod's command-
  -- line echoes when enabled: run quietly, and remember WHERE we executed from so
  -- dbout can trail ghost text on that line once the result lands.
  local quiet = self.config.results.query_time.enabled
  local origin = { bufnr = vim.api.nvim_get_current_buf(), lnum = vim.fn.line('.') }

  -- Fire `on_execute_query` before anything is dispatched to the engine. The
  -- event carries the SQL lines, the resolved connection (when the buffer is a
  -- tracked dbui query buffer), the origin buffer and the visual flag. Isolated
  -- (a throwing hook never blocks execution). Observers only -- the return is
  -- ignored, so a hook can inspect/log the query but not rewrite it here.
  local raw_key = vim.b.dbui_db_key_name
  local pre_entry = self.instance.dbs[raw_key]
  local raw_db = vim.b.db
  ---@type string
  local pre_url = ''
  if pre_entry ~= nil then
    pre_url = pre_entry.conn or ''
  elseif type(raw_db) == 'string' then
    pre_url = raw_db
  end
  hooks.run(self.config, 'on_execute_query', {
    sql = lines,
    url = pre_url,
    name = pre_entry ~= nil and pre_entry.name or '',
    key_name = type(raw_key) == 'string' and raw_key or '',
    bufnr = origin.bufnr,
    is_visual = is_visual == true,
  })

  -- Shared tail: arm the ghost-text origin (consumed synchronously by dbout's
  -- DBExecutePre hook), dispatch `action` through dadbod, surface its error as a
  -- notification, and remember the query. Both the fast path and the bind-param
  -- path end the same way.
  ---@param action fun(): nil
  ---@return nil
  local function run(action)
    dbout.arm_origin(origin)
    local ok, err = pcall(action)
    if not ok then
      dbout.disarm_origin()
      return notify.error(clean_execute_error(err))
    end
    self.last_query = lines
  end

  -- Apply `transform` (if any) to `sql_lines`, returning the lines to run and
  -- whether the SQL was rewritten. `mutated` lets callers drop the whole-buffer
  -- `%DB` fast path (the buffer text no longer matches what runs). A nil transform,
  -- or one that returns nil, is the identity (mutated=false), preserving today's
  -- exact execution paths.
  ---@param sql_lines string[]
  ---@return string[] lines
  ---@return boolean mutated
  local function transformed(sql_lines)
    if transform == nil then
      return sql_lines, false
    end
    local new_sql = transform(table.concat(sql_lines, '\n'))
    if new_sql == nil then
      return sql_lines, false
    end
    return vim.split(new_sql, '\n'), true
  end

  -- The connection is captured before any async prompt so execution targets it
  -- even if focus moves while a prompt is open.
  local entry = self.instance.dbs[vim.b.dbui_db_key_name]
  if entry == nil then
    -- Not a tracked dbui query buffer (bind params and `transform` are dbui-
    -- query-buffer features, so neither applies here): a visual run needs the
    -- connection, but a whole-buffer run without placeholders can still go
    -- straight through `%DB` on the buffer's b:db, preserving the public
    -- execute_query contract for plain buffers.
    if is_visual or #bind_params.detect(lines, self.config.query.bind_param_pattern) > 0 then
      return notify.error('Buffer not attached to any database')
    end
    return run(function()
      bridge.execute_buffer(quiet, self.config.results.layout == 'vertical')
    end)
  end

  self:with_resolved_sql(lines, 'executed', function(resolved, substituted)
    -- Substitute bind params first, THEN transform -- the hook sees the runnable
    -- SQL, not raw `:placeholder` tokens. A substituted or transformed run no
    -- longer matches the buffer text, so it drops the whole-buffer `%DB` fast
    -- path and dispatches from a temp file; the whole-buffer non-paginated,
    -- untouched case still goes through `dispatch`'s `%DB` path.
    local final, mutated = transformed(resolved)
    run(function()
      self:dispatch(final, entry, (not is_visual) and not substituted and not mutated, quiet)
    end)
  end)
end

--- Explain the current query buffer (or visual selection): wrap its SQL in the
--- adapter's EXPLAIN syntax and run it into the `.dbout` window, the explain dual
--- of `execute_query`. Reuses the same buffer read (`get_lines`), connection
--- (`b:dbui_db_key_name`) and bind-parameter flow -- placeholders are prompted and
--- substituted BEFORE wrapping, so the plan reflects the query you'd actually run.
--- Explain output is never paginated. `opts.analyze` selects `EXPLAIN ANALYZE`
--- (which RUNS the query). An adapter without explain support (or without an
--- executing form, for `analyze`) surfaces `dadbod-ui.explain`'s user error as a
--- notification and runs nothing. Backs `api.buf.explain`/`explain_selection`.
---@param is_visual? boolean
---@param opts? DadbodUI.ExplainOpts
---@return nil
function Query:explain_query(is_visual, opts)
  local lines = self:get_lines(is_visual)
  local entry = self.instance.dbs[vim.b.dbui_db_key_name]
  if entry == nil then
    return notify.error('Buffer not attached to any database')
  end
  -- Wrap the (already param-substituted) SQL in the adapter's EXPLAIN syntax and
  -- run it from a temp file. `explain.wrap` returns the user-facing error for an
  -- unsupported adapter / analyze form -- surface it and run nothing.
  self:with_resolved_sql(lines, 'explained', function(final_lines)
    local wrapped, err = explain.wrap(entry.scheme, table.concat(final_lines, '\n'), opts)
    if wrapped == nil then
      return notify.error(err)
    end
    local ok, run_err = pcall(function()
      self:run_from_file(vim.split(wrapped, '\n'), entry)
    end)
    if not ok then
      return notify.error(clean_execute_error(run_err))
    end
    self.last_query = final_lines
  end)
end

--- Explain the current query buffer (or visual selection) as an interactive
--- plan TREE: wrap the SQL in the adapter's JSON EXPLAIN form, run it through
--- the adapter's own client (headless -- no `.dbout` window), and open the
--- parsed plan in the explain-tree split. The tree dual of `explain_query`,
--- sharing its buffer read, connection and bind-parameter flow.
--- `opts.analyze` runs the executing JSON form (rolled back for DML where the
--- dialect allows). Requires a live connection (the client needs the resolved
--- url); unsupported adapters surface `dadbod-ui.explain`'s user error.
---@param is_visual? boolean
---@param opts? DadbodUI.ExplainOpts
---@return nil
function Query:explain_tree(is_visual, opts)
  local lines = self:get_lines(is_visual)
  local entry = self.instance.dbs[vim.b.dbui_db_key_name]
  if entry == nil then
    return notify.error('Buffer not attached to any database')
  end
  if entry.conn == nil or entry.conn == '' then
    return notify.error('Not connected. Open the connection in the drawer first.')
  end
  self:with_resolved_sql(lines, 'explained', function(final_lines)
    local sql = table.concat(final_lines, '\n')
    explain_run.open_tree({
      scheme = entry.scheme,
      conn = entry.conn,
      sql = sql,
      analyze = opts ~= nil and opts.analyze or nil,
    })
    self.last_query = final_lines
  end)
end

--- Export the current query buffer (or visual selection) to a file: run its SQL
--- and write the RESULTS in a chosen format, the export dual of `execute_query`
--- and the query-buffer counterpart to `.dbout`'s `export_result`. Reuses the same
--- buffer read (`get_lines`), connection (`b:dbui_db_key_name`) and bind-parameter
--- flow -- placeholders are prompted and substituted BEFORE the query runs, so the
--- file reflects the query you'd actually execute. Hands the resolved query +
--- connection to `export.export_prompt`, which prompts for format + path. The
--- output filename defaults to the buffer's table name (`b:dbui_table_name`) when
--- set, else a name derived from the query. Backs `api.buf.export`/`export_selection`.
---@param is_visual? boolean
---@return nil
function Query:export_query(is_visual)
  local lines = self:get_lines(is_visual)
  local entry = self.instance.dbs[vim.b.dbui_db_key_name]
  if entry == nil then
    return notify.error('Buffer not attached to any database')
  end
  -- Read the table name now: an async bind-param prompt may resolve after focus
  -- has moved off this buffer. Empty (a scratch query) => let export derive one.
  local raw_table = vim.b.dbui_table_name
  local source = (type(raw_table) == 'string' and raw_table ~= '') and raw_table or nil

  -- Hand the (already param-substituted) SQL to the shared interactive export core.
  self:with_resolved_sql(lines, 'exported', function(final_lines)
    export.export_prompt({
      url = entry.conn,
      scheme = entry.scheme,
      query = table.concat(final_lines, '\n'),
      source = source,
    })
  end)
end

--- Cancel the running async query for the current query buffer (`api.buf.cancel`
--- / the `cancel` query mapping), through `bridge.cancel`. Gated on
--- `bridge.can_cancel()`: when dadbod exposes no async cancellation there is
--- nothing to cancel, so we notify and -- deliberately -- fire NO hooks (the
--- cancel lifecycle only runs when a cancel can actually happen). Otherwise
--- `on_cancel_query` fires before the cancel and `on_cancel_query_post` after,
--- each isolated so a throwing hook never breaks the cancel.
---@return nil
function Query:cancel_query()
  local bufnr = vim.api.nvim_get_current_buf()
  if not bridge.can_cancel() then
    return notify.info('No cancellable query is running.')
  end
  hooks.run(self.config, 'on_cancel_query', { bufnr = bufnr })
  bridge.cancel(bufnr)
  hooks.run(self.config, 'on_cancel_query_post', { bufnr = bufnr })
end

--- Set or revise a bind parameter (`<Leader>E`). Unions the
--- placeholders detected in the buffer (in query order) with any stored names no
--- longer present, so you can pre-fill a value BEFORE the first run instead of
--- hitting a dead end. Unanswered params show as "Not provided" in the picker.
--- With one candidate we edit it directly; with several, the injectable picker
--- chooses which. The new value is prefilled with the current one; cancelling
--- leaves it unchanged. Entering an empty value keeps the entry but makes the
--- placeholder a raw literal on the next run (the documented escape hatch).
--- Delete is intentionally dropped -- edit-to-empty covers the only behavior it
--- offered.
---@return nil
function Query:edit_bind_parameters()
  local bufnr = vim.api.nvim_get_current_buf()
  local params = stored_params(bufnr)

  -- Candidates: placeholders in the buffer first (query order, already distinct
  -- from detect), then any stored names no longer in the buffer (sorted, for
  -- stability).
  local names = bind_params.detect(self:get_lines(), self.config.query.bind_param_pattern)
  local orphans = vim
    .iter(vim.tbl_keys(params))
    :filter(function(name)
      return not vim.tbl_contains(names, name)
    end)
    :totable()
  table.sort(orphans)
  vim.list_extend(names, orphans)

  if #names == 0 then
    return notify.info('No bind parameters to edit.')
  end

  local function edit_one(name)
    self.input({ prompt = string.format('Edit value for %s -> ', name), default = params[name] }, function(val)
      if val == nil then
        return -- cancelled, no change
      end
      -- The prompt is async: the buffer may have been wiped while it was open.
      -- There is nothing to run here, so abort with a notification rather than
      -- throwing on the buffer-var write.
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return notify.warn('Buffer no longer available; bind parameter not saved.')
      end
      local updated = stored_params(bufnr)
      updated[name] = val
      vim.b[bufnr].dbui_bind_params = updated
      notify.info(string.format('Updated bind parameter %s.', name))
    end)
  end

  if #names == 1 then
    return edit_one(names[1])
  end
  self.select(names, {
    prompt = 'Select bind parameter to edit:',
    -- Annotate each name with its current value (or "Not provided") without
    -- changing the item handed back to on_choice.
    format_item = function(name)
      local val = params[name]
      local shown = (val ~= nil and vim.trim(val) ~= '') and val or 'Not provided'
      return string.format('%s = %s', name, shown)
    end,
  }, function(choice)
    if choice ~= nil then
      edit_one(choice)
    end
  end)
end

--- The last executed query and its runtime. `last_query` is captured
--- synchronously on dispatch; `last_query_time` (seconds) is recorded by
--- `dadbod-ui.dbout` once the async result lands (dadbod's `b:db.runtime`), so it
--- is `''` until the first result comes back.
---@return DadbodUI.LastQueryInfo
function Query:get_last_query_info()
  return { last_query = self.last_query, last_query_time = self.last_query_time }
end

return Query
