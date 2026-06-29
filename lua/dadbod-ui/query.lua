---@mod dadbod-ui.query  Query buffers: open, set the b:dbui_* contract, execute
---
--- Faithful port of vim-dadbod-ui's `autoload/db_ui/query.vim`. A `Query` is
--- created over the drawer (so it can re-render and connect through the same
--- backends) and owns the SQL buffers: opening a `New query` or a table-helper
--- buffer, setting the buffer-local contract verbatim (`b:dbui_db_key_name`,
--- `b:db`, `b:dbui_table_name`, `b:dbui_schema_name`), and executing on save
--- through the bridge's async `:DB` path. Bind parameters (M9) are detected on
--- execute, prompted for, persisted in `b:dbui_bind_params`, and substituted
--- before the SQL reaches the engine; the in-buffer loading symbol and result
--- tracking live in `dadbod-ui.dbout`.

local bridge = require('dadbod-ui.bridge')
local bind_params = require('dadbod-ui.bind_params')
local utils = require('dadbod-ui.utils')

local M = {}

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

---@class DadbodUI.Query
---@field drawer DadbodUI.Drawer
---@field instance DadbodUI.Instance
---@field config DadbodUI.Config
---@field input DadbodUI.UiInput  prompt backend (shared with the drawer; injectable)
---@field select DadbodUI.UiSelect  picker backend for the edit flow (injectable)
---@field last_query string[]  lines of the most recently executed query
local Query = {}
Query.__index = Query

--- Create a query controller bound to `drawer`.
---@param drawer DadbodUI.Drawer
---@return DadbodUI.Query
function M.new(drawer)
  return setmetatable({
    drawer = drawer,
    instance = drawer.instance,
    config = drawer.config,
    input = drawer.input,
    select = vim.ui.select,
    last_query = {},
  }, Query)
end

--- Open the buffer a drawer `item` points at. `buffer`/`saved_query` items open
--- their existing file; every other openable item (New query, a table helper)
--- builds a fresh buffer name and pre-fills the templated query. Port of
--- `s:query.open`.
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

--- Build the on-disk name for a new query buffer: `<slug(name-suffix)>-<time>`,
--- where the suffix is `query` or `<table>-<label>`. Honors a configured
--- `buffer_name_generator`, prefers the tmp-query location, and otherwise drops
--- it next to `tempname()` (tracking it as a tmp buffer). Port of
--- `s:query.generate_buffer_name`.
---@param entry DadbodUI.ConnectionEntry
---@param opts { label: string, table?: string, schema?: string, filetype: string }
---@return string
function Query:generate_buffer_name(entry, opts)
  local time = vim.fn.strftime('%Y-%m-%d-%H-%M-%S')
  local suffix = 'query'
  if opts.table ~= nil and opts.table ~= '' then
    suffix = string.format('%s-%s', opts.table, opts.label)
  end
  local buffer_name = utils.slug(string.format('%s-%s', entry.name, suffix))
  buffer_name = string.format('%s-%s', buffer_name, time)
  if self.config.buffer_name_generator then
    buffer_name = string.format('%s-%s', entry.name, self.config.buffer_name_generator(opts))
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
--- on the side opposite the drawer. Port of `s:query.focus_window`.
---@return nil
function Query:focus_window()
  local win_cmd = 'vertical ' .. utils.opposite_position(self.config.win_position) .. ' new'
  local wins = vim.api.nvim_tabpage_list_wins(0)
  if #wins == 1 then
    vim.cmd('silent! ' .. win_cmd)
    return
  end
  -- (a) reuse a window already holding a dbui query buffer.
  for _, win in ipairs(wins) do
    local buf = vim.api.nvim_win_get_buf(win)
    local key = vim.b[buf].dbui_db_key_name
    if key and key ~= '' then
      vim.api.nvim_set_current_win(win)
      return
    end
  end
  -- (b) else any normal editable window.
  for _, win in ipairs(wins) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype ~= 'dbui' and vim.bo[buf].buftype ~= 'nofile' and vim.bo[buf].modifiable then
      vim.api.nvim_set_current_win(win)
      return
    end
  end
  -- (c) else open a vertical split on the side opposite the drawer.
  vim.cmd('silent! ' .. win_cmd)
end

--- Open `name` for `entry` via `edit_action`, set the buffer contract, and (for
--- table-helper opens) substitute the placeholders into the templated query and
--- optionally auto-execute. Connects the entry first so `b:db` is a live handle.
--- Port of `s:query.open_buffer`.
---@param entry DadbodUI.ConnectionEntry
---@param name string
---@param edit_action string
---@param opts? { table?: string, schema?: string, content?: string, existing_buffer?: boolean }
---@return nil
function Query:open_buffer(entry, name, edit_action, opts)
  opts = opts or {}
  local table_name = opts.table or ''
  local schema = opts.schema or ''
  local default_content = opts.content or self.config.default_query

  -- Ensure a live connection so b:db works for execution even when the buffer
  -- is opened on a not-yet-expanded connection (mirrors find_buffer's connect).
  self.drawer:connect(entry)

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
    local pos = utils.opposite_position(self.config.win_position)
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

  if self.config.auto_execute_table_helpers then
    if self.config.execute_on_save then
      vim.cmd('write')
    else
      self:execute_query()
    end
  end
end

--- Set the buffer-local contract, register the buffer with its connection,
--- configure buffer options, and wire the execute-on-save / cleanup autocmds.
--- Port of `s:query.setup_buffer`.
---@param entry DadbodUI.ConnectionEntry
---@param opts { table?: string, schema?: string, existing_buffer?: boolean }
---@param name string
---@return nil
function Query:setup_buffer(entry, opts, name)
  vim.b.dbui_db_key_name = entry.key_name
  vim.b.dbui_table_name = opts.table or ''
  vim.b.dbui_schema_name = opts.schema or ''
  vim.b.db = entry.conn
  local is_existing = opts.existing_buffer or false
  local db_buffers = entry.buffers

  if not vim.tbl_contains(db_buffers.list, name) then
    if #db_buffers.list == 0 then
      db_buffers.expanded = true
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

  if not (self.config.disable_mappings or self.config.disable_mappings_sql) then
    vim.keymap.set('n', '<Leader>S', function()
      self:execute_query()
    end, { buffer = bufnr, silent = true })
    vim.keymap.set('v', '<Leader>S', function()
      self:execute_query(true)
    end, { buffer = bufnr, silent = true })
    vim.keymap.set('n', '<Leader>E', function()
      self:edit_bind_parameters()
    end, { buffer = bufnr, silent = true })
    if is_tmp and is_sql then
      vim.keymap.set('n', '<Leader>W', function()
        self:save_query()
      end, { buffer = bufnr, silent = true })
    end
  end

  local group = vim.api.nvim_create_augroup('dadbod_ui_query_' .. bufnr, { clear = true })
  if self.config.execute_on_save and is_sql then
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
end

--- The buffer (or, in visual mode, the last selection) as a line list. Reads the
--- selection with `getregion` over the `'<`/`'>` marks instead of `gvy`, so it
--- never runs a normal-mode yank or touches the unnamed register. `exclusive =
--- false` reproduces the original `selection=inclusive` yank regardless of the
--- user's `&selection`. Port of `s:query.get_lines`.
---@param is_visual? boolean
---@return string[]
function Query:get_lines(is_visual)
  if not is_visual then
    return vim.api.nvim_buf_get_lines(0, 0, -1, false)
  end
  return vim.fn.getregion(vim.fn.getpos("'<"), vim.fn.getpos("'>"), {
    type = vim.fn.visualmode(),
    exclusive = false,
  })
end

--- Reduce a raw `vim.cmd` error from dadbod to its user-facing message: strip
--- the Lua/`nvim_exec2`/`Vim(echoerr):` wrappers, leaving e.g. `DB: Query
--- already running for this tab`.
---@param err any
---@return string
local function clean_execute_error(err)
  local s = tostring(err)
  return s:match('Vim%b():(.+)$') or s:match('DB:.+$') or s
end

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
  local pending = {}
  for _, name in ipairs(names) do
    if values[name] == nil then
      pending[#pending + 1] = name
    end
  end
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

--- Run already-substituted `lines` through the engine via a temp file. The
--- rewritten SQL can be multi-statement and contain arbitrary characters, so we
--- write it out and let dadbod read it (`DB <url> < file`) rather than building a
--- command string. The temp file uses the adapter's input extension. `entry` is
--- captured before prompting so execution targets the right connection even if
--- focus moved while an async prompt was open.
---@param lines string[]
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Query:run_from_file(lines, entry)
  local ext = bridge.input_extension(entry.conn) or 'sql'
  local file = vim.fn.tempname() .. '.' .. ext
  vim.fn.writefile(lines, file)
  bridge.execute_file(file, entry.conn)
end

--- Execute the current query buffer (or visual selection) through dadbod. With
--- no placeholders we keep the direct fast path -- the whole buffer via `%DB` or
--- the selection via `'<,'>DB` -- so dadbod operates on the live buffer/selection
--- unchanged. When `bind_param_pattern` matches, we prompt for any not-yet-known
--- parameters, persist the full set in `b:dbui_bind_params`, substitute the
--- quoted values, and run the rewritten SQL from a temp file. Cancelling a prompt
--- aborts without executing or persisting. Dadbod errors (e.g. a query already
--- running for the tab) surface as a notification rather than a raw stack trace.
--- Port of `s:query.execute_query` + `execute_lines` + `inject_variables`.
---@param is_visual? boolean
---@return nil
function Query:execute_query(is_visual)
  local notify = require('dadbod-ui.notifications')
  local lines = self:get_lines(is_visual)
  local pattern = self.config.bind_param_pattern
  local names = bind_params.detect(lines, pattern)

  -- Shared tail: dispatch `action` through dadbod, surface its error as a
  -- notification, announce the async run, and remember the query. Both the
  -- fast path and the bind-param path end the same way.
  ---@param action fun(): nil
  ---@return nil
  local function run(action)
    local ok, err = pcall(action)
    if not ok then
      return notify.error(clean_execute_error(err))
    end
    if bridge.can_cancel() then
      notify.info('Executing query...')
    end
    self.last_query = lines
  end

  if #names == 0 then
    -- Fast path: no placeholders, run the buffer/selection directly.
    return run(is_visual and bridge.execute_range or bridge.execute_buffer)
  end

  -- Capture buffer and connection now: an async prompt backend may resolve after
  -- focus has moved, so we must not read the current buffer in the callback.
  local bufnr = vim.api.nvim_get_current_buf()
  local entry = self.instance.dbs[vim.b.dbui_db_key_name]
  if entry == nil then
    return notify.error('Buffer not attached to any database')
  end
  prompt_params(self.input, names, stored_params(bufnr), function(values)
    if values == nil then
      return notify.info('Bind parameters cancelled. Query not executed.')
    end
    vim.b[bufnr].dbui_bind_params = values
    local final = bind_params.substitute(lines, values, pattern)
    run(function()
      self:run_from_file(final, entry)
    end)
  end)
end

--- Set or revise a bind parameter (`<Leader>E`). Improves on the original, which
--- could only touch parameters already answered via execute: we union the
--- placeholders detected in the buffer (in query order) with any stored names no
--- longer present, so you can pre-fill a value BEFORE the first run instead of
--- hitting a dead end. Unanswered params show as "Not provided" in the picker.
--- With one candidate we edit it directly; with several, the injectable picker
--- chooses which. The new value is prefilled with the current one; cancelling
--- leaves it unchanged. Entering an empty value keeps the entry but makes the
--- placeholder a raw literal on the next run (the documented escape hatch).
--- Delete is intentionally dropped -- edit-to-empty covers the only behavior it
--- offered. Port of `s:query.edit_bind_parameters`.
---@return nil
function Query:edit_bind_parameters()
  local notify = require('dadbod-ui.notifications')
  local bufnr = vim.api.nvim_get_current_buf()
  local params = stored_params(bufnr)

  -- Candidates: placeholders in the buffer first (query order, already distinct
  -- from detect), then any stored names no longer in the buffer (sorted, for
  -- stability).
  local names = bind_params.detect(self:get_lines(), self.config.bind_param_pattern)
  local seen = {}
  for _, name in ipairs(names) do
    seen[name] = true
  end
  local orphans = {}
  for name in pairs(params) do
    if not seen[name] then
      orphans[#orphans + 1] = name
    end
  end
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
--- Port of `s:query.remove_buffer`.
---@param bufnr integer
---@return nil
function Query:remove_buffer(bufnr)
  local key = vim.fn.getbufvar(bufnr, 'dbui_db_key_name')
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
--- existing file. Port of `s:query.save_query` (callback-shaped for our async
--- prompt backend).
---@return nil
function Query:save_query()
  local notify = require('dadbod-ui.notifications')
  local entry = self.instance.dbs[vim.b.dbui_db_key_name]
  if entry == nil then
    return notify.error('Buffer not attached to any database')
  end
  if entry.save_path == '' then
    return notify.error('Save location is empty. Please provide valid directory to g:db_ui_save_location')
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
    self.drawer:load_saved_queries(entry)
    self.drawer:render()
    self:open_buffer(entry, full_name, 'edit')
  end)
end

--- The last executed query and its (M11) timing. Port of
--- `s:query.get_last_query_info`.
---@return { last_query: string[] }
function Query:get_last_query_info()
  return { last_query = self.last_query }
end

M.Query = Query
return M
