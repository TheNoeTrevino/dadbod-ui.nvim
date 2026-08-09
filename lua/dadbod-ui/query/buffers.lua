-- Buffer lifecycle for query buffers
--
-- A method mixin merged into `DadbodUI.Query` by `query/init.lua`: opening
-- drawer items into SQL buffers, buffer naming and window focus, the
-- buffer-local contract (`write_contract`/`setup_buffer`), the "Script As"
-- destinations, saving a scratch query, and the exit sweep that settles
-- modified scratch buffers on quit.

local constants = require('dadbod-ui.constants')
local utils = require('dadbod-ui.utils')
local notify = require('dadbod-ui.notifications')
local mappings = require('dadbod-ui.mappings')

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

---@private
-- The dbui connection key of the buffer shown in `win`, or nil when the window
-- doesn't hold a query buffer (no `b:dbui_db_key_name` contract). The single
-- predicate for "is this a dbui query window", shared by `focus_window` (which
-- reuses one) and `active_query_buf` (which writes into one).
---@param win integer
---@return string|nil
local function query_win_key(win)
  local key = vim.b[vim.api.nvim_win_get_buf(win)].dbui_db_key_name
  if key == nil or key == '' then
    return nil
  end
  return key
end

---@class DadbodUI.Query
local Query = {}

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

--- Build the on-disk name for a new query buffer: `<base>.<ext>` inside the
--- connection's own tmp folder (`entry.tmp_path`), where the base is `query` or
--- `<table>-<label>` and `<ext>` is the adapter's query-input extension
--- (`entry.extension`, e.g. `sql`). The folder records ownership (`state`
--- restores its contents on startup, `entry_for_dir` resolves it back), and the
--- real extension makes the buffer look like a genuine query file to external
--- formatters/linters/LSP, which key off the filename rather than Neovim's
--- `filetype`. A taken name bumps a `-N` counter. Honors a configured
--- `buffer_name_generator` (whose output is used verbatim -- no extension or
--- counter is forced onto a user-supplied name).
---@param entry DadbodUI.ConnectionEntry
---@param opts { label: string, table?: string, schema?: string, filetype: string }
---@return string
function Query:generate_buffer_name(entry, opts)
  vim.fn.mkdir(entry.tmp_path, 'p')
  if self.config.buffer_name_generator then
    return string.format('%s/%s', entry.tmp_path, self.config.buffer_name_generator(opts))
  end
  local base = 'query'
  if opts.table ~= nil and opts.table ~= '' then
    base = string.format('%s-%s', opts.table, opts.label)
  end
  local name = string.format('%s/%s.%s', entry.tmp_path, base, entry.extension)
  local n = 1
  while utils.is_file(name) or vim.tbl_contains(entry.buffers, name) do
    n = n + 1
    name = string.format('%s/%s-%d.%s', entry.tmp_path, base, n, entry.extension)
  end
  return name
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
  local reuse = vim.iter(wins):find(query_win_key)
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
---@param opts? { table?: string, schema?: string, content?: string, raw?: boolean, existing_buffer?: boolean }
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
  -- Show an already-open buffer as-is (don't clobber its contents). If the window
  -- won't take it (an unrelated modified buffer under 'nohidden' -- query buffers
  -- themselves never block, see setup_buffer's 'bufhidden=hide'), the switch is a
  -- no-op and we fall through to the split below.
  local is_existing = utils.loaded_bufnr(full) > -1
  if is_existing then
    pcall(vim.cmd, 'silent! buffer ' .. vim.fn.fnameescape(full))
    if utils.same_path(vim.api.nvim_buf_get_name(0), full) then
      self:setup_buffer(entry, vim.tbl_extend('force', opts, { existing_buffer = true }), name)
      return
    end
  end

  vim.cmd('silent! ' .. edit_action .. ' ' .. vim.fn.fnameescape(name))
  if not utils.same_path(vim.api.nvim_buf_get_name(0), full) then
    -- The window could not take the buffer (an unrelated modified buffer under
    -- 'nohidden'). Open in a fresh split so the query buffer still appears and
    -- that modified buffer is never abandoned.
    local pos = utils.opposite_position(self.config.drawer.position)
    vim.cmd('silent! vertical ' .. pos .. ' split ' .. vim.fn.fnameescape(name))
  end
  self:setup_buffer(entry, vim.tbl_extend('force', opts, { existing_buffer = is_existing }), name)

  -- `raw` fills a fresh buffer with `content` verbatim: no `{placeholder}`
  -- substitution and no auto-execute (the "Script As" flow writes finished DDL,
  -- e.g. a DROP, that must never run just from being opened). An already-open
  -- buffer is shown untouched, exactly like the templated path.
  if opts.raw then
    if not is_existing then
      vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(opts.content or '', '\n'))
    end
    return
  end

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

--- Focus and return the bufnr of the current tabpage's active query buffer for
--- `entry` (a window whose buffer carries the `b:dbui_db_key_name` contract),
--- preferring this connection's own buffer but accepting any dbui query buffer.
--- Returns nil when none is visible -- the "Script As" replace/append
--- destinations fall back to a new buffer in that case.
---@param entry DadbodUI.ConnectionEntry
---@return integer|nil
function Query:active_query_buf(entry)
  -- One pass: an exact connection match wins outright; otherwise fall back to the
  -- first query window of any connection.
  local win
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local key = query_win_key(w)
    if key ~= nil then
      if key == entry.key_name then
        win = w
        break
      end
      win = win or w
    end
  end
  if win == nil then
    return nil
  end
  vim.api.nvim_set_current_win(win)
  return vim.api.nvim_win_get_buf(win)
end

--- Write scripted routine DDL (`text`) to a "Script As" destination:
---  `new`     -- a fresh query buffer for `entry`, filled verbatim (no execute);
---  `replace` -- overwrite the active query buffer's contents;
---  `append`  -- add it below the active query buffer's contents (blank-separated).
--- `replace`/`append` fall back to a new buffer when no query buffer is visible.
---@param entry DadbodUI.ConnectionEntry
---@param dest 'new'|'replace'|'append'
---@param text string
---@param opts? { table?: string, schema?: string }
---@return nil
function Query:write_script(entry, dest, text, opts)
  opts = opts or {}
  if dest ~= 'new' then
    local buf = self:active_query_buf(entry)
    if buf ~= nil then
      local script_lines = vim.split(text, '\n')
      local count = vim.api.nvim_buf_line_count(buf)
      local is_empty = count == 1 and (vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or '') == ''
      if dest == 'replace' or is_empty then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, script_lines)
      else
        vim.api.nvim_buf_set_lines(buf, count, count, false, vim.list_extend({ '' }, script_lines))
      end
      return
    end
    -- no visible query buffer: fall through and open a fresh one
  end
  local name = self:generate_buffer_name(entry, {
    label = 'script',
    table = opts.table,
    schema = opts.schema,
    filetype = entry.filetype,
  })
  self:open_buffer(entry, name, 'edit', { content = text, raw = true, table = opts.table, schema = opts.schema })
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
  if not vim.tbl_contains(entry.buffers, name) then
    if #entry.buffers == 0 then
      -- The connection's first open buffer: expand its Buffers section so the
      -- buffer is visible in the drawer right away.
      self.drawer:expand_section(entry.key_name, 'buffers')
    end
    table.insert(entry.buffers, name)
    self.drawer:render()
  end

  if vim.bo.filetype ~= entry.filetype or not is_existing then
    -- Guard the filetype switch: a third-party `FileType` autocmd that errors
    -- (e.g. a completion plugin) must not abort opening the buffer. The option
    -- is applied before any autocmd runs, so an error leaves the filetype set
    -- and we still fall through to fill/return the buffer.
    -- `bufhidden=hide` keeps query buffers swappable out of their window even
    -- under 'nohidden', so open_buffer can reuse the one query window instead of
    -- splitting (the old buffer hides -- still loaded, still in the drawer).
    local ok, err =
      pcall(vim.cmd, 'setlocal noswapfile nowrap nospell modifiable bufhidden=hide filetype=' .. entry.filetype)
    if not ok and self.config.debug then
      notify.warn('Error in FileType autocmd: ' .. tostring(err))
    end
  end
  local is_sql = vim.bo.filetype == entry.filetype
  local is_tmp = self.instance:is_tmp_location_buffer(name)
  local bufnr = vim.api.nvim_get_current_buf()

  do
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
      explain_tree = function(mode)
        self:explain_tree(mode == 'v')
      end,
      explain_tree_analyze = function(mode)
        self:explain_tree(mode == 'v', { analyze = true })
      end,
      goto_table = function()
        self.drawer:goto_table()
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
    -- Required lazily: this mixin is loaded by query/init.lua, so a top-level
    -- require would be circular. By the time a buffer is set up the facade is
    -- fully loaded.
    local query_mod = require('dadbod-ui.query')
    local function apply()
      -- Rendered per apply (not once at setup) so a recolored connection paints
      -- its new color the next time the buffer enters a window.
      local winbar = query_mod.connection_winbar(entry, self.instance:connection_color(entry))
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

---@private
--- Is `bufnr` a modified SCRATCH query buffer -- the only thing the quit sweep
--- may touch? Requires the `b:dbui_db_key_name` contract (so it is a tracked dbui
--- buffer, not some unrelated SQL file), a real file buffer, and a name under the
--- tmp location. Saved queries live under `save_path`, so they fail the last test
--- and keep Vim's normal prompt -- they are real files the user deliberately named.
---@param instance DadbodUI.Instance
---@param bufnr integer
---@return boolean
local function is_scratch_buf(instance, bufnr)
  if not vim.api.nvim_buf_is_loaded(bufnr) or not vim.bo[bufnr].modified then
    return false
  end
  if vim.bo[bufnr].buftype ~= '' then
    return false
  end
  local key = vim.b[bufnr].dbui_db_key_name
  if type(key) ~= 'string' or key == '' then
    return false
  end
  return instance:is_tmp_location_buffer(vim.api.nvim_buf_get_name(bufnr))
end

--- Resolve every modified scratch query buffer so quitting doesn't raise Vim's
--- "No write since last change" prompt once per buffer (`setup_buffer`'s
--- `bufhidden=hide` keeps the whole session's scratch buffers loaded, so the
--- prompts pile up -- see issue #74). Driven by `config.query.save_on_exit`;
--- `'ask'` is a no-op that leaves Vim's prompt alone.
---
--- `'auto'` defers to `Instance:persists_scratch` -- the same predicate that
--- decides whether `state` restores a connection's scratch `buffers` on startup,
--- so the two halves cannot drift apart. With a tmp location the buffers are
--- written, because they come back next session; without one their folder is the
--- session temp dir, which Neovim wipes on exit, so the prompt asks about a file
--- that cannot outlive the answer. Saved queries are never swept.
---@return nil
function Query:sweep_on_exit()
  local mode = self.config.query.save_on_exit
  if mode == 'ask' then
    return -- leave Vim's own prompt alone
  end
  -- 'discard' never writes; 'auto' writes only what state will restore.
  local persist = mode == 'auto' and self.instance:persists_scratch()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if is_scratch_buf(self.instance, bufnr) then
      if persist then
        -- `noautocmd`: a plain write fires BufWritePost, which under
        -- `execute_on_save` would run every scratch query on the way out.
        vim.api.nvim_buf_call(bufnr, function()
          pcall(vim.cmd, 'silent! noautocmd write')
        end)
      else
        vim.bo[bufnr].modified = false
      end
    end
  end
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
  local target = vim.fn.bufname(bufnr)
  local function keep(path)
    return not utils.same_path(path, target)
  end
  entry.buffers = vim.tbl_filter(keep, entry.buffers)
  self.drawer:render()
end

--- Save the current query buffer to the connection's save_path under a name the
--- user provides, then reopen it as a saved query. Rejects a blank name or an
--- existing file. Callback-shaped for the async prompt backend.
---@return nil
function Query:save_query()
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

return Query
