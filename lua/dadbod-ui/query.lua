-- Query buffers: open, set the b:dbui_* contract, execute
--
-- A `Query` is created over the drawer and owns the SQL buffers: opening a
-- `New query` or a table-helper buffer, setting the buffer-local contract
-- (`b:dbui_db_key_name`, `b:db`, `b:dbui_table_name`, `b:dbui_schema_name`),
-- and executing on save through the bridge's async `:DB` path. Bind parameters
-- (M9) are detected on execute, prompted for, persisted in `b:dbui_bind_params`,
-- and substituted before the SQL reaches the engine; the in-buffer loading
-- symbol and result tracking live in `dadbod-ui.dbout`.
--
-- Connecting and refreshing saved queries go through an injected
-- `dadbod-ui.introspect` controller (an acyclic leaf), not back through the
-- drawer. The one drawer back-ref is `drawer:render()` -- the drawer owns the
-- tree, so a buffer change that should refresh it asks the drawer to redraw.
-- (The drawer in turn reaches back into the query controller for `open_buffer`,
-- e.g. when renaming a buffer file.)

local constants = require('dadbod-ui.constants')
local bridge = require('dadbod-ui.bridge')
local bind_params = require('dadbod-ui.bind_params')
local introspect = require('dadbod-ui.introspect')
local utils = require('dadbod-ui.utils')

--- A last-mile SQL rewrite hook for `execute_query`/`execute_selection`. Receives
--- the runnable SQL (a single string, after bind-param substitution) and returns
--- the SQL to run instead -- e.g. wrapping the query in EXPLAIN. Returning nil
--- runs the query unchanged.
---@alias DadbodUI.SqlTransform fun(sql: string): string|nil

---@class DadbodUI.QueryModule
---@field connection_winbar fun(entry: DadbodUI.ConnectionEntry): string
---@field new fun(drawer: DadbodUI.Drawer): DadbodUI.Query
---@field Query DadbodUI.Query  the class table, exported for the static `write_contract`

---@type DadbodUI.QueryModule
---@diagnostic disable-next-line: missing-fields
local M = {}

---@private
-- Monotonic suffix for generated buffer names, so two buffers created within the
-- same second don't collide on the second-precision timestamp.
local name_seq = 0

---@private
--- Replace every literal occurrence of `key` in `s` with `val`. Uses a function
--- replacement so `%` in `val` (and Lua pattern magic generally) stays literal;
--- `key` is escaped so `{...}` placeholders match as plain text.
---@param s string
---@param key string
---@param val string
---@return string
local function subst(s, key, val)
  return (s:gsub(vim.pesc(key), function()
    return val
  end))
end

--- The right-aligned connection winbar for a query buffer: `group/name` (or just
--- `name` when the connection is ungrouped) in a padded, highlighted block pushed
--- to the right edge with `%=`. `%` in the group/name is doubled so a name can't
--- inject statusline items. Pure (no window), for unit tests.
---@param entry DadbodUI.ConnectionEntry
---@return string
function M.connection_winbar(entry)
  local text = utils.display_name(entry.name, entry.group)
  return string.format('%%=%%#DadbodUIWinbarConnection# %s ', (text:gsub('%%', '%%%%')))
end

---@class DadbodUI.Query
---@field drawer DadbodUI.Drawer  back-ref, used only for drawer:render()
---@field instance DadbodUI.Instance
---@field config DadbodUI.Config
---@field input DadbodUI.UiInput  prompt backend (shared with the drawer; injectable)
---@field select DadbodUI.UiSelect  picker backend for the edit flow (injectable)
---@field introspect DadbodUI.Introspect  connect / load-saved-queries backend
---@field last_query string[]  lines of the most recently executed query
---@field last_query_time string  runtime of the last result in seconds ('' until one lands)
local Query = {}
Query.__index = Query

--- Create a query controller bound to `drawer`. Connecting and saved-query
--- refresh go through a dedicated introspection controller (built from the
--- drawer's config + injectable connect backend) rather than back through the
--- drawer, so this module depends on `dadbod-ui.introspect` (a leaf), not on a
--- drawer↔query cycle.
---@param drawer DadbodUI.Drawer
---@return DadbodUI.Query
function M.new(drawer)
  return setmetatable({
    drawer = drawer,
    instance = drawer.instance,
    config = drawer.config,
    input = drawer.input,
    select = vim.ui.select,
    introspect = introspect.new({
      config = drawer.config,
      connector = drawer.connector,
      render = function()
        drawer:render()
      end,
    }),
    last_query = {},
    last_query_time = '',
  }, Query)
end

--- Open the buffer a drawer `item` points at. `buffer`/`saved_query` items open
--- their existing file; every other openable item (New query, a table helper)
--- builds a fresh buffer name and pre-fills the templated query.
---@param item DadbodUI.Node
---@param edit_action string  'edit' | 'vertical … split' | …
---@return nil
function Query:open(item, edit_action)
  local entry = self.instance.dbs[item.key_name]
  if entry == nil then
    return
  end
  if item.type == 'buffer' or item.type == 'saved_query' then
    return self:open_buffer(entry, item.file_path, edit_action)
  end
  local label = item.label or ''
  local table_name = ''
  local schema = ''
  if item.type ~= 'query' then
    table_name = item.table or ''
    schema = item.schema or ''
  end
  local buffer_name = self:generate_buffer_name(entry, {
    schema = schema,
    table = table_name,
    label = label,
    filetype = entry.filetype,
  })
  self:open_buffer(entry, buffer_name, edit_action, {
    table = table_name,
    content = item.content,
    schema = schema,
  })
end

--- Build the on-disk name for a new query buffer:
--- `<slug(name-suffix)>-<time>.<ext>`, where the suffix is `query` or
--- `<table>-<label>` and `<ext>` is the adapter's query-input extension
--- (`entry.extension`, e.g. `sql`). The real extension makes the buffer look like
--- a genuine query file to external formatters/linters/LSP, which key off the
--- filename rather than Neovim's `filetype`. Honors a configured
--- `buffer_name_generator` (whose output is used verbatim -- no extension is
--- forced onto a user-supplied name), prefers the tmp-query location, and
--- otherwise drops it next to `tempname()` (tracking it as a tmp buffer).
---@param entry DadbodUI.ConnectionEntry
---@param opts { label: string, table?: string, schema?: string, filetype: string }
---@return string
function Query:generate_buffer_name(entry, opts)
  name_seq = name_seq + 1
  local time = vim.fn.strftime('%Y-%m-%d-%H-%M-%S') .. '-' .. name_seq
  local suffix = 'query'
  if opts.table ~= nil and opts.table ~= '' then
    suffix = string.format('%s-%s', opts.table, opts.label)
  end
  -- Prefix with the group-qualified name (not the bare `entry.name`) so tmp query
  -- files for a name reused across groups stay namespaced and resolve back to the
  -- right connection (see get_saved_query_db_name / Drawer:pick_db).
  local buffer_name = utils.slug(string.format('%s-%s', entry.save_name, suffix))
  buffer_name = string.format('%s-%s.%s', buffer_name, time, entry.extension)
  if self.config.buffer_name_generator then
    buffer_name = string.format('%s-%s', entry.save_name, self.config.buffer_name_generator(opts))
  end
  if self.instance.tmp_location ~= '' then
    return string.format('%s/%s', self.instance.tmp_location, buffer_name)
  end
  local tmp_name = string.format('%s/%s', vim.fs.dirname(vim.fn.tempname()), buffer_name)
  table.insert(entry.buffers.tmp, tmp_name)
  return tmp_name
end

--- Move to a window suitable for the query buffer: reuse one already holding a
--- dbui query buffer, else a normal editable window, else open a vertical split
--- on the side opposite the drawer.
---@return nil
function Query:focus_window()
  local win_cmd = 'vertical ' .. utils.opposite_position(self.config.drawer.position) .. ' new'
  local wins = vim.api.nvim_tabpage_list_wins(0)
  if #wins == 1 then
    vim.cmd('silent! ' .. win_cmd)
    return
  end
  -- (a) reuse a window already holding a dbui query buffer.
  local reuse = vim.iter(wins):find(function(win)
    local key = vim.b[vim.api.nvim_win_get_buf(win)].dbui_db_key_name
    return key and key ~= ''
  end)
  if reuse then
    vim.api.nvim_set_current_win(reuse)
    return
  end
  -- (b) else any normal editable window.
  local editable = vim.iter(wins):find(function(win)
    local buf = vim.api.nvim_win_get_buf(win)
    return vim.bo[buf].filetype ~= constants.drawer_filetype
      and vim.bo[buf].buftype ~= 'nofile'
      and vim.bo[buf].modifiable
  end)
  if editable then
    vim.api.nvim_set_current_win(editable)
    return
  end
  -- (c) else open a vertical split on the side opposite the drawer.
  vim.cmd('silent! ' .. win_cmd)
end

--- Open `name` for `entry` via `edit_action`, set the buffer contract, and (for
--- table-helper opens) substitute the placeholders into the templated query and
--- optionally auto-execute. Connects the entry first so `b:db` is a live handle.
---@param entry DadbodUI.ConnectionEntry
---@param name string
---@param edit_action string
---@param opts? { table?: string, schema?: string, content?: string, existing_buffer?: boolean }
---@return nil
function Query:open_buffer(entry, name, edit_action, opts)
  opts = opts or {}
  local table_name = opts.table or ''
  local schema = opts.schema or ''
  local default_content = opts.content or self.config.query.default_query

  -- Ensure a live connection so b:db works for execution even when the buffer
  -- is opened on a not-yet-expanded connection (mirrors find_buffer's connect).
  self.introspect:connect(entry)

  local full = vim.fn.fnamemodify(name, ':p')
  if edit_action == 'edit' then
    self:focus_window()
  end
  -- An already-open buffer is shown as-is (don't clobber its contents). When the
  -- window can't be reused -- e.g. 'nohidden' with a modified buffer in it -- the
  -- switch is a no-op, so we fall through to the split fallback below.
  local is_existing = utils.loaded_bufnr(full) > -1
  if is_existing then
    pcall(vim.cmd, 'silent! buffer ' .. vim.fn.fnameescape(full))
    if vim.api.nvim_buf_get_name(0) == full then
      self:setup_buffer(entry, vim.tbl_extend('force', opts, { existing_buffer = true }), name)
      return
    end
  end

  vim.cmd('silent! ' .. edit_action .. ' ' .. vim.fn.fnameescape(name))
  if vim.api.nvim_buf_get_name(0) ~= full then
    -- The window could not take the buffer (modified buffer + 'nohidden'). Open
    -- in a fresh split so the query buffer still appears -- a split keeps the
    -- modified buffer visible in its original window, so it is never abandoned.
    local pos = utils.opposite_position(self.config.drawer.position)
    vim.cmd('silent! vertical ' .. pos .. ' split ' .. vim.fn.fnameescape(name))
  end
  self:setup_buffer(entry, vim.tbl_extend('force', opts, { existing_buffer = is_existing }), name)

  if table_name == '' or is_existing then
    return
  end

  local optional_schema = schema == entry.default_scheme and '' or schema
  if optional_schema ~= '' then
    if entry.quote then
      optional_schema = '"' .. optional_schema .. '"'
    end
    optional_schema = optional_schema .. '.'
  end

  local db_name = schema ~= '' and schema or entry.db_name
  local content = default_content
  content = subst(content, '{table}', table_name)
  content = subst(content, '{optional_schema}', optional_schema)
  content = subst(content, '{schema}', schema)
  content = subst(content, '{dbname}', db_name)
  content = subst(content, '{last_query}', table.concat(self.last_query, '\n'))

  vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(content, '\n'))

  if self.config.query.auto_execute_table_helpers then
    if self.config.query.execute_on_save then
      vim.cmd('write')
    else
      self:execute_query()
    end
  end
end

--- Write the buffer-local interop contract (`b:dbui_db_key_name`, `b:db`,
--- `b:dbui_table_name`, `b:dbui_schema_name`, and `b:dbui_bind_params` when
--- given) onto `bufnr`. The single place that ESTABLISHES the contract -- both
--- the query-open path and the drawer's buffer rename route through here, so the
--- fixed names are written in one spot (`b:dbui_bind_params` is afterwards
--- updated in place by the bind-param flow). `b:db` is dadbod's live handle
--- (`entry.conn`); the rest are dadbod-ui's own.
---@param bufnr integer
---@param entry DadbodUI.ConnectionEntry
---@param opts DadbodUI.ContractOpts
---@return nil
function Query.write_contract(bufnr, entry, opts)
  local b = vim.b[bufnr]
  b.dbui_db_key_name = entry.key_name
  b.db = entry.conn
  b.dbui_table_name = opts.table or ''
  b.dbui_schema_name = opts.schema or ''
  if opts.bind_params ~= nil then
    b.dbui_bind_params = opts.bind_params
  end
end

--- Set the buffer-local contract, register the buffer with its connection,
--- configure buffer options, and wire the execute-on-save / cleanup autocmds.
---@param entry DadbodUI.ConnectionEntry
---@param opts { table?: string, schema?: string, existing_buffer?: boolean }
---@param name string
---@return nil
function Query:setup_buffer(entry, opts, name)
  Query.write_contract(vim.api.nvim_get_current_buf(), entry, opts)
  local is_existing = opts.existing_buffer or false
  local db_buffers = entry.buffers

  if not vim.tbl_contains(db_buffers.list, name) then
    if #db_buffers.list == 0 then
      -- The connection's first open buffer: expand its Buffers section so the
      -- buffer is visible in the drawer right away.
      self.drawer:expand_section(entry.key_name, 'buffers')
    end
    table.insert(db_buffers.list, name)
    self.drawer:render()
  end

  if vim.bo.filetype ~= entry.filetype or not is_existing then
    -- Guard the filetype switch: a third-party `FileType` autocmd that errors
    -- (e.g. a completion plugin) must not abort opening the buffer. The option
    -- is applied before any autocmd runs, so an error leaves the filetype set
    -- and we still fall through to fill/return the buffer.
    local ok, err = pcall(vim.cmd, 'setlocal noswapfile nowrap nospell modifiable filetype=' .. entry.filetype)
    if not ok and self.config.debug then
      require('dadbod-ui.notifications').warn('Error in FileType autocmd: ' .. tostring(err))
    end
  end
  local is_sql = vim.bo.filetype == entry.filetype
  local is_tmp = self.instance:is_tmp_location_buffer(entry, name)
  local bufnr = vim.api.nvim_get_current_buf()

  do
    local mappings = require('dadbod-ui.mappings')
    -- Keyed by the ids in `config.builtin_actions.query`; the same ids drive the
    -- help window. `execute` is mode-aware (visual runs the selection).
    -- `save_query` is offered only for writable tmp SQL buffers, so it is omitted
    -- otherwise. `apply` no-ops when `config.query.keys` is `false`.
    local handlers = {
      execute = function(mode)
        self:execute_query(mode == 'v')
      end,
      edit_bind_params = function()
        self:edit_bind_parameters()
      end,
      cancel = function()
        self:cancel_query()
      end,
    }
    if is_tmp and is_sql then
      handlers.save_query = function()
        self:save_query()
      end
    end
    local function make_ctx(mode)
      return { mode = mode, bufnr = bufnr, query = self, connection = self.instance.dbs[vim.b[bufnr].dbui_db_key_name] }
    end
    mappings.apply(
      self.config.query.keys,
      handlers,
      self.config.actions,
      make_ctx,
      { buffer = bufnr, silent = true, nowait = true }
    )
  end

  local group = vim.api.nvim_create_augroup('dadbod_ui_query_' .. bufnr, { clear = true })
  if self.config.query.execute_on_save and is_sql then
    vim.api.nvim_create_autocmd('BufWritePost', {
      group = group,
      buffer = bufnr,
      nested = true,
      callback = function()
        self:execute_query()
      end,
    })
  end
  vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
    group = group,
    buffer = bufnr,
    callback = function(args)
      self:remove_buffer(args.buf)
    end,
  })

  -- Show which connection this buffer targets in a right-aligned winbar. Applied
  -- to every window already showing the buffer, and re-applied on BufWinEnter so
  -- it follows the buffer into a new split (mirrors dbout's win_findbuf re-apply).
  -- The winbar string is self-contained (leads with `%=`), so re-entering the
  -- buffer overwrites rather than stacks. The BufWinLeave teardown clears the
  -- window's winbar when this buffer leaves it, so the connection can't linger
  -- over whatever buffer is shown there next (mirrors dbout's arm_winbar_teardown).
  -- Switching between two query buffers in one window stays correct: the leaving
  -- buffer clears the winbar, then the entering buffer's own BufWinEnter re-applies
  -- its connection. Result/drawer buffers are separate and untouched -- these
  -- autocmds are buffer-local to the query buffer.
  if self.config.query.show_buffer_connection then
    local winbar = M.connection_winbar(entry)
    local function apply()
      for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
        pcall(vim.api.nvim_set_option_value, 'winbar', winbar, { win = win })
      end
    end
    apply()
    vim.api.nvim_create_autocmd('BufWinEnter', { group = group, buffer = bufnr, callback = apply })
    vim.api.nvim_create_autocmd('BufWinLeave', {
      group = group,
      buffer = bufnr,
      callback = function()
        local win = vim.fn.bufwinid(bufnr)
        if win ~= -1 then
          pcall(vim.api.nvim_set_option_value, 'winbar', '', { win = win })
        end
      end,
    })
  end
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
  local resolved = require('dadbod-ui.hooks').call(config, 'resolve_bind_params', names, known)
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
  local paginator = require('dadbod-ui.paginator')
  local dbout = require('dadbod-ui.dbout')
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
  local notify = require('dadbod-ui.notifications')
  local dbout = require('dadbod-ui.dbout')
  local lines = self:get_lines(is_visual)
  local pattern = self.config.query.bind_param_pattern
  local names = bind_params.detect(lines, pattern)

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
  require('dadbod-ui.hooks').run(self.config, 'on_execute_query', {
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

  if #names == 0 then
    -- No placeholders. Whole-buffer and visual both flow through `dispatch`, which
    -- auto-paginates a plain SELECT (page 1) and otherwise runs unmodified -- the
    -- whole-buffer non-paginated, non-transformed case still uses the fast `%DB` path.
    local entry = self.instance.dbs[vim.b.dbui_db_key_name]
    if entry == nil then
      -- Not a tracked dbui query buffer (`transform` is a dbui-query-buffer
      -- feature, so it does not apply here): a visual run needs the connection, but
      -- a whole-buffer run can still go straight through `%DB` on the buffer's b:db,
      -- preserving the public execute_query contract for plain buffers.
      if is_visual then
        return notify.error('Buffer not attached to any database')
      end
      return run(function()
        bridge.execute_buffer(quiet, self.config.results.layout == 'vertical')
      end)
    end
    local final, mutated = transformed(lines)
    return run(function()
      self:dispatch(final, entry, (not is_visual) and not mutated, quiet)
    end)
  end

  -- Capture buffer and connection now: an async prompt backend may resolve after
  -- focus has moved, so we must not read the current buffer in the callback.
  local bufnr = vim.api.nvim_get_current_buf()
  local entry = self.instance.dbs[vim.b.dbui_db_key_name]
  if entry == nil then
    return notify.error('Buffer not attached to any database')
  end
  resolve_params(self.config, self.input, names, stored_params(bufnr), function(values)
    if values == nil then
      return notify.info('Bind parameters cancelled. Query not executed.')
    end
    -- The async prompt may resolve after the origin buffer was wiped (see the
    -- focus-change note above); persist the answers only when it still exists,
    -- but run the query regardless -- execution targets the captured `entry`, not
    -- the current buffer.
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.b[bufnr].dbui_bind_params = values
    end
    -- Substitute bind params first, THEN transform -- the hook sees the runnable
    -- SQL, not raw `:placeholder` tokens. This is already a substituted (non-whole-
    -- buffer) run, so the transform's `mutated` flag is moot: either way it
    -- dispatches from a temp file.
    local final = transformed(bind_params.substitute(lines, values, pattern))
    run(function()
      self:dispatch(final, entry, false, quiet)
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
  local notify = require('dadbod-ui.notifications')
  local explain = require('dadbod-ui.explain')
  local lines = self:get_lines(is_visual)
  local entry = self.instance.dbs[vim.b.dbui_db_key_name]
  if entry == nil then
    return notify.error('Buffer not attached to any database')
  end
  local pattern = self.config.query.bind_param_pattern
  local names = bind_params.detect(lines, pattern)

  -- Wrap the (already param-substituted) SQL in the adapter's EXPLAIN syntax and
  -- run it from a temp file. `explain.wrap` returns the user-facing error for an
  -- unsupported adapter / analyze form -- surface it and run nothing.
  local function explain_and_run(final_lines)
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
  end

  if #names == 0 then
    return explain_and_run(lines)
  end

  -- Capture the buffer now: an async prompt may resolve after focus has moved.
  local bufnr = vim.api.nvim_get_current_buf()
  resolve_params(self.config, self.input, names, stored_params(bufnr), function(values)
    if values == nil then
      return notify.info('Bind parameters cancelled. Query not explained.')
    end
    vim.b[bufnr].dbui_bind_params = values
    explain_and_run(bind_params.substitute(lines, values, pattern))
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
  local notify = require('dadbod-ui.notifications')
  local export = require('dadbod-ui.export')
  local lines = self:get_lines(is_visual)
  local entry = self.instance.dbs[vim.b.dbui_db_key_name]
  if entry == nil then
    return notify.error('Buffer not attached to any database')
  end
  -- Read the table name now: an async bind-param prompt may resolve after focus
  -- has moved off this buffer. Empty (a scratch query) => let export derive one.
  local raw_table = vim.b.dbui_table_name
  local source = (type(raw_table) == 'string' and raw_table ~= '') and raw_table or nil
  local pattern = self.config.query.bind_param_pattern
  local names = bind_params.detect(lines, pattern)

  -- Hand the (already param-substituted) SQL to the shared interactive export core.
  local function export_lines(final_lines)
    export.export_prompt({
      url = entry.conn,
      scheme = entry.scheme,
      query = table.concat(final_lines, '\n'),
      source = source,
    })
  end

  if #names == 0 then
    return export_lines(lines)
  end

  -- Capture the buffer now: an async prompt may resolve after focus has moved.
  local bufnr = vim.api.nvim_get_current_buf()
  resolve_params(self.config, self.input, names, stored_params(bufnr), function(values)
    if values == nil then
      return notify.info('Bind parameters cancelled. Query not exported.')
    end
    vim.b[bufnr].dbui_bind_params = values
    export_lines(bind_params.substitute(lines, values, pattern))
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
  local notify = require('dadbod-ui.notifications')
  local hooks = require('dadbod-ui.hooks')
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
  local notify = require('dadbod-ui.notifications')
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

--- Drop a wiped/deleted buffer from its connection's buffer lists and re-render.
---@param bufnr integer
---@return nil
function Query:remove_buffer(bufnr)
  local key = vim.b[bufnr].dbui_db_key_name
  local entry = self.instance.dbs[key]
  if entry == nil then
    return
  end
  local target = vim.fn.fnamemodify(vim.fn.bufname(bufnr), ':p')
  local function keep(path)
    return vim.fn.fnamemodify(path, ':p') ~= target
  end
  entry.buffers.list = vim.tbl_filter(keep, entry.buffers.list)
  entry.buffers.tmp = vim.tbl_filter(keep, entry.buffers.tmp)
  self.drawer:render()
end

--- Save the current query buffer to the connection's save_path under a name the
--- user provides, then reopen it as a saved query. Rejects a blank name or an
--- existing file. Callback-shaped for the async prompt backend.
---@return nil
function Query:save_query()
  local notify = require('dadbod-ui.notifications')
  local entry = self.instance.dbs[vim.b.dbui_db_key_name]
  if entry == nil then
    return notify.error('Buffer not attached to any database')
  end
  if entry.save_path == '' then
    return notify.error('Save location is empty. Please provide a valid directory via setup({ save_location = ... })')
  end
  if not utils.is_dir(entry.save_path) then
    vim.fn.mkdir(entry.save_path, 'p')
  end
  self.input({ prompt = 'Save as: ' }, function(name)
    if name == nil then
      return
    end
    name = vim.trim(name)
    if name == '' then
      return notify.error('No valid name provided.')
    end
    local full_name = string.format('%s/%s', entry.save_path, name)
    if utils.is_file(full_name) then
      return notify.error('That file already exists. Please choose another name.')
    end
    vim.cmd('write ' .. vim.fn.fnameescape(full_name))
    self.introspect:load_saved_queries(entry)
    self.drawer:render()
    self:open_buffer(entry, full_name, 'edit')
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

--- Best-effort connection name for a buffer that carries no `b:dbui_db_key_name`
--- yet, inferred from its on-disk location so `find_buffer` can adopt a plain
--- `.sql` file opened under the tmp-query or save directory. A tmp-location file
--- matches the `<name>-…` buffer prefix (stripping a leading `db_ui.` root); a
--- save-location file lives in a per-connection subdir named for the db. Returns
--- `''` when nothing matches.
---@return string
function Query:get_saved_query_db_name()
  local dir = vim.fn.expand('%:p:h')
  local tmp = self.instance.tmp_location
  if tmp ~= '' and tmp == dir then
    local filename = vim.fn.expand('%:t')
    if vim.fn.fnamemodify(filename, ':r') == 'db_ui' then
      filename = vim.fn.fnamemodify(filename, ':e')
    end
    local match = vim.iter(self.instance.dbs_list):find(function(record)
      local qname = utils.qualified_name(record.name, record.group)
      return filename:match('^' .. vim.pesc(qname) .. '%-') ~= nil
    end)
    if match ~= nil then
      -- Return the group-qualified name so a name reused across groups maps back
      -- to THIS connection (pick_db matches on the qualified name too).
      return utils.qualified_name(match.name, match.group)
    end
  end
  if vim.fs.dirname(dir) == self.instance.save_path then
    return vim.fs.basename(dir)
  end
  return ''
end

M.Query = Query
return M
