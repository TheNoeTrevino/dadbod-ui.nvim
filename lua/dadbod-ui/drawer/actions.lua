-- Cursor/interaction verbs on the drawer tree
--
-- A method mixin merged into `DadbodUI.Drawer` by `drawer/init.lua`: the node
-- under the cursor is resolved via `get_current_item` and acted on -- toggles,
-- opens, the interactive connection CRUD dispatchers, buffer rename/delete,
-- find/reveal, and sibling/parent navigation.

local bridge = require('dadbod-ui.bridge')
local spinner = require('dadbod-ui.spinner')
local utils = require('dadbod-ui.utils')

---@private
-- The connected predicate lives in state (the SSOT); required lazily here to
-- keep the dependency graph acyclic, mirroring the lazy state require in M.new.
---@param entry DadbodUI.ConnectionEntry
---@return boolean
local function is_connected(entry)
  return require('dadbod-ui.state').is_connected(entry)
end

---@class DadbodUI.Drawer
local Drawer = {}

---@return DadbodUI.Drawer
function Drawer:toggle_help()
  if self.help_winid and vim.api.nvim_win_is_valid(self.help_winid) then
    vim.api.nvim_win_close(self.help_winid, true)
    self.help_winid = nil
    return self
  end

  -- Built from `config.mappings` so the help window and the live keymaps can
  -- never drift; disabled (`key = 'none'`) actions are already filtered out.
  local lines = require('dadbod-ui.mappings').help_lines(self.config)
  local max_len = 0
  for _, line in ipairs(lines) do
    if #line > max_len then
      max_len = #line
    end
  end

  local width = math.min(max_len + 4, vim.o.columns - 4)
  local height = #lines
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.bo[buf].bufhidden = 'wipe'

  local winid = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row = row,
    col = col,
    width = width,
    height = height,
    border = 'rounded',
    title = ' Help ',
    title_pos = 'center',
    style = 'minimal',
  })
  self.help_winid = winid

  local function close()
    if vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_win_close(winid, true)
    end
    self.help_winid = nil
  end

  for _, key in ipairs({ 'q', '<Esc>', '?' }) do
    vim.keymap.set('n', key, close, { buffer = buf, nowait = true, silent = true })
  end

  vim.api.nvim_create_autocmd('BufLeave', {
    buffer = buf,
    once = true,
    callback = function()
      -- window may already be gone if a keymap closed it
      pcall(vim.api.nvim_win_close, winid, true)
      self.help_winid = nil
    end,
  })

  return self
end

---@return DadbodUI.Drawer
function Drawer:toggle_details()
  self.show_details = not self.show_details
  return self:render()
end

--- Refresh `entry.saved_queries.list` from disk. Thin wrapper over the
--- introspection controller (which owns it so the query controller can refresh
--- saved queries without a drawer back-ref), exposed here for the drawer's own
--- callers and the saved-query specs.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Drawer:load_saved_queries(entry)
  return self:introspect():load_saved_queries(entry)
end

---@return integer
function Drawer:current_line()
  return vim.api.nvim_win_get_cursor(self.winid)[1]
end

---@param line integer
function Drawer:set_cursor(line)
  line = math.max(1, math.min(line, #self.content))
  local col = vim.api.nvim_win_get_cursor(self.winid)[2]
  vim.api.nvim_win_set_cursor(self.winid, { line, col })
end

--- The node under the cursor (or nil).
---@return DadbodUI.Node|nil
function Drawer:get_current_item()
  if not self:is_open() then
    return nil
  end
  return self.content[self:current_line()]
end

-- Expand/UI state ownership ---------------------------------------------------
--
-- Two coherent owners:
--   * DRAWER owns transient VIEW state -- `help_winid`, `show_details`,
--     `show_dbout_list`, and group expand (`self.groups`, via `group_state`).
--     None of it is domain data; it resets with a fresh drawer.
--   * ENTRIES own DOMAIN expand -- `entry.expanded` and the `.expanded` flag on
--     each section/schema/table sub-node; per-connection, surviving a drawer
--     close/reopen on the same instance.
--
-- `toggle_line` special-cases neither: every togglable node carries a
-- `toggle_state` reference to its backing `{ expanded }` table (see the Node
-- type for what each points at), so a toggle is one generic flip, plus an
-- optional `on_expand` for the db's lazy introspection.
--
-- `show_dbout_list` is the lone exception: like the `show_details` boolean it
-- is flipped by name, here on the `call_method` path. It is left there
-- deliberately to keep the action branches (`call_method`/`open`) untouched --
-- those are actions, not expand-state flips.

--- Act on the node under the cursor. Toggles groups/dbs/sections; opens query,
--- buffer, saved-query and table-helper nodes through the query controller (in
--- `edit_action`, defaulting to `edit`); previews dbout result files.
---@param edit_action? string  'edit' | 'vertical … split' (default 'edit')
---@return DadbodUI.Drawer|nil
function Drawer:toggle_line(edit_action)
  local item = self:get_current_item()
  if item == nil or item.action == 'noaction' then
    return
  end
  if item.action == 'call_method' then
    if item.type == 'add_connection' then
      self:connections():add_connection()
    elseif item.type == 'dbout_list' then
      self.show_dbout_list = not self.show_dbout_list
      return self:render()
    end
    return
  end
  if item.action == 'open' then
    if item.type == 'dbout' then
      self:query():focus_window()
      vim.cmd('silent! pedit ' .. vim.fn.fnameescape(item.file_path))
      return
    end
    self:query():open(item, edit_action or 'edit')
    return
  end
  -- Generic flip (see the ownership note above): every togglable node carries
  -- `toggle_state`; `on_expand` (db lazy introspection) fires only when the flip
  -- opens the node, never on collapse.
  if item.toggle_state ~= nil then
    item.toggle_state.expanded = not item.toggle_state.expanded
    if item.toggle_state.expanded then
      if item.on_expand ~= nil then
        item.on_expand()
      end
    elseif item.type == 'db' and item.key_name ~= nil then
      -- Collapsing a db that may still be mid-load: stop its loading animation
      -- and drop the marker so no timer leaks and no stale spinner reappears.
      spinner.stop(item.key_name)
      local entry = self.instance.dbs[item.key_name]
      if entry ~= nil then
        entry.loading = false
      end
    end
    return self:render()
  end
end

-- Interactive connection management ------------------------------------------
--
-- The CRUD flows (prompt -> validate -> pure transform -> write/re-render) now
-- live in `dadbod-ui.connections_controller`, built lazily via
-- `self:connections()`. The cursor-aware `*_line` dispatchers below resolve the
-- node under the cursor and route to that controller.

--- Group the connection under the cursor (`G`).
---@return nil
function Drawer:set_group_line()
  local item = self:get_current_item()
  if item == nil then
    return
  end
  if item.type == 'db' then
    return self:connections():set_group(self.instance.dbs[item.key_name])
  end
end

--- Place the cursor on the `db` node for `key_name` (best-effort). Used to keep a
--- connection under the cursor after a reorder/paste re-renders and shuffles the
--- line list.
---@param key_name string
---@return nil
function Drawer:focus_db(key_name)
  if not self:is_open() then
    return
  end
  for idx, node in ipairs(self.content) do
    if node.type == 'db' and node.key_name == key_name then
      pcall(vim.api.nvim_win_set_cursor, self.winid, { idx, 0 })
      return
    end
  end
end

--- Place the cursor on the connection identified by (name, url), regardless of
--- its current group -- used after a `<C-Up>`/`<C-Down>` move that may have
--- changed the connection's group (and thus its key_name). Falls back to the
--- connection's group header when its db line is hidden inside a collapsed group.
---@param name string
---@param url string
---@return nil
function Drawer:focus_conn(name, url)
  if not self:is_open() then
    return
  end
  local resolved = bridge.resolve(url):lower()
  local target_group = nil
  for _, record in ipairs(self.instance.dbs_list) do
    local entry = self.instance.dbs[record.key_name]
    if entry ~= nil and entry.name:lower() == name:lower() and bridge.resolve(entry.url):lower() == resolved then
      target_group = entry.group or ''
      for idx, node in ipairs(self.content) do
        if node.type == 'db' and node.key_name == record.key_name then
          pcall(vim.api.nvim_win_set_cursor, self.winid, { idx, 0 })
          return
        end
      end
      break
    end
  end
  -- The db line isn't rendered (its group is collapsed): land on the header.
  if target_group ~= nil and target_group ~= '' then
    for idx, node in ipairs(self.content) do
      if node.type == 'group' and node.group == target_group then
        pcall(vim.api.nvim_win_set_cursor, self.winid, { idx, 0 })
        return
      end
    end
  end
end

--- Move the connection under the cursor up/down (`<C-Up>`/`<C-Down>`), crossing
--- group boundaries as it goes (see `connections.move_connection`). Keeps the
--- cursor on the moved connection after the re-render -- its group (hence
--- key_name) may change when it crosses a boundary, so we re-find it by name+url
--- via `focus_conn` rather than the stale key_name.
---@param direction 'up'|'down'
---@return nil
function Drawer:move_line(direction)
  local item = self:get_current_item()
  if item == nil or item.type ~= 'db' or item.key_name == nil then
    return
  end
  local entry = self.instance.dbs[item.key_name]
  self:connections():move_connection(entry, direction)
  self:focus_conn(entry.name, entry.url)
end

--- Duplicate the connection under the cursor (`D`).
---@return nil
function Drawer:duplicate_line()
  local item = self:get_current_item()
  if item == nil then
    return
  end
  if item.type == 'db' then
    return self:connections():duplicate_connection(self.instance.dbs[item.key_name])
  end
end

--- Delete the connection under the cursor (`d`). Only file-source connections
--- can be deleted; others are refused. Asks for confirmation first.
---@return nil
function Drawer:delete_line()
  local item = self:get_current_item()
  if item == nil or item.action == 'noaction' then
    return
  end
  if item.action == 'toggle' and item.type == 'db' then
    local entry = self.instance.dbs[item.key_name]
    if entry.source ~= 'file' then
      return require('dadbod-ui.notifications').error('Cannot delete this connection.')
    end
    return self:connections():delete_connection(entry)
  end
  if item.action == 'open' and (item.type == 'buffer' or item.type == 'saved_query') then
    return self:delete_buffer(item)
  end
end

--- Delete a saved query or tmp query buffer (the file and all its tracking),
--- after confirmation. Saved queries leave file connections' disk store; tmp
--- buffers only exist in the tmp location. Port of the buffer branch of
--- `s:drawer.delete_line`.
---@param item DadbodUI.Node
---@return nil
function Drawer:delete_buffer(item)
  local notify = require('dadbod-ui.notifications')
  local entry = self.instance.dbs[item.key_name]
  local file = item.file_path
  if entry == nil or file == nil then
    return
  end
  local function drop(list)
    return vim.tbl_filter(function(v)
      return v ~= file
    end, list)
  end
  if item.saved then
    if not self.confirm('Are you sure you want to delete this saved query?') then
      return
    end
    vim.fn.delete(file)
    entry.saved_queries.list = drop(entry.saved_queries.list)
    entry.buffers.list = drop(entry.buffers.list)
    notify.info('Deleted.')
  elseif self.instance:is_tmp_location_buffer(entry, file) then
    if not self.confirm('Are you sure you want to delete query?') then
      return
    end
    vim.fn.delete(file)
    entry.buffers.list = drop(entry.buffers.list)
    notify.info('Deleted.')
  else
    return
  end
  local bufnr = utils.loaded_bufnr(file)
  if bufnr > -1 then
    local win = vim.fn.bufwinnr(bufnr)
    if win > -1 then
      vim.cmd(win .. 'wincmd w')
      vim.cmd('silent! b#')
    end
    vim.cmd('silent! bwipeout! ' .. bufnr)
  end
  if self:is_open() then
    vim.api.nvim_set_current_win(self.winid)
  end
  self:render()
end

--- Rename the node under the cursor (`r`). Connections route to the CRUD
--- controller; open buffers and saved queries route to `rename_buffer`.
---@return nil
function Drawer:rename_line()
  local item = self:get_current_item()
  if item == nil then
    return
  end
  if item.type == 'buffer' or item.type == 'saved_query' then
    return self:rename_buffer(item.file_path, item.key_name, item.saved or false)
  end
  if item.type == 'db' then
    return self:connections():rename_connection(self.instance.dbs[item.key_name])
  end
end

--- Rename a written query file on disk and move its buffer tracking to the new
--- name, transferring the buffer-local contract. Saved queries keep their bare
--- name; tmp buffers are re-prefixed with the connection slug. Port of
--- `s:drawer.rename_buffer` (callback-shaped for our async prompt backend).
---@param buffer string  the file being renamed
---@param key_name string  the owning connection's key
---@param is_saved_query boolean
---@return nil
function Drawer:rename_buffer(buffer, key_name, is_saved_query)
  local notify = require('dadbod-ui.notifications')
  if not utils.is_file(buffer) then
    return notify.error('Only written queries can be renamed.')
  end
  if key_name == nil or key_name == '' then
    return notify.error('Buffer not attached to any database')
  end
  local entry = self.instance.dbs[key_name]
  if entry == nil then
    return notify.error('Buffer not attached to any database')
  end
  local db_slug = utils.slug(entry.name)
  local is_saved = is_saved_query or not self.instance:is_tmp_location_buffer(entry, buffer)
  local old_name = self:get_buffer_name(entry, buffer)
  self.input({ prompt = 'Enter new name: ', default = old_name }, function(new_name)
    if new_name == nil then
      return
    end
    new_name = vim.trim(new_name)
    if new_name == '' then
      return notify.error('Valid name must be provided.')
    end
    local dir = vim.fn.fnamemodify(buffer, ':p:h')
    local new
    if is_saved then
      new = string.format('%s/%s', dir, new_name)
    else
      new = string.format('%s/%s-%s', dir, db_slug, new_name)
      table.insert(entry.buffers.tmp, new)
    end
    vim.fn.rename(buffer, new)

    local bufnr = vim.fn.bufnr(buffer)
    local bufwin = bufnr > -1 and vim.fn.bufwinnr(bufnr) or -1
    local new_bufnr = -1
    if bufwin > -1 then
      self:query():open_buffer(entry, new, 'edit')
      new_bufnr = vim.api.nvim_get_current_buf()
    elseif bufnr > -1 then
      vim.cmd('badd ' .. vim.fn.fnameescape(new))
      new_bufnr = vim.fn.bufnr(new)
      table.insert(entry.buffers.list, new)
    else
      local idx = vim.fn.index(entry.buffers.list, buffer)
      if idx > -1 then
        table.insert(entry.buffers.list, idx + 1, new)
      end
    end
    entry.buffers.list = vim.tbl_filter(function(v)
      return v ~= buffer
    end, entry.buffers.list)

    if new_bufnr > -1 then
      -- Carry the contract onto the renamed buffer through the single writer,
      -- preserving the old buffer's table name and bind params (the latter is a
      -- bare '' when the source was never parametrized -- round-tripped as-is).
      -- Read from the old buffer's number (already resolved above), not its
      -- name, so getbufvar resolves the buffer once rather than per field.
      self:query().write_contract(new_bufnr, entry, {
        table = vim.fn.getbufvar(bufnr, 'dbui_table_name'),
        schema = vim.fn.getbufvar(bufnr, 'dbui_schema_name'),
        bind_params = vim.fn.getbufvar(bufnr, 'dbui_bind_params'),
      })
    end

    vim.cmd('silent! bwipeout! ' .. vim.fn.fnameescape(buffer))
    self:load_saved_queries(entry)
    if self:is_open() then
      vim.api.nvim_set_current_win(self.winid)
    end
    self:render()
  end)
end

--- Resolve which connection to adopt for a buffer that has no `b:dbui_db_key_name`
--- yet, then hand it to `cb`. `saved_name` is the best-effort name inferred from
--- the buffer's path (`Query:get_saved_query_db_name`): non-empty picks that db by
--- name; otherwise a lone connection is taken automatically and several prompt the
--- (injectable) selector. `cb` receives the entry, or nil when nothing resolves or
--- the user cancels. Port of `s:get_db` (callback-shaped for the async selector).
---@param saved_name string
---@param cb fun(entry: DadbodUI.ConnectionEntry|nil)
---@return nil
function Drawer:pick_db(saved_name, cb)
  local list = self.instance.dbs_list
  ---@param r DadbodUI.ConnectionRecord|nil
  ---@return DadbodUI.ConnectionEntry|nil
  local function entry_of(r)
    return r and self.instance.dbs[r.key_name] or nil
  end
  if #list == 0 then
    return cb(nil)
  end
  if saved_name ~= '' then
    return cb(entry_of(vim.iter(list):find(function(r)
      return r.name:lower() == saved_name:lower()
    end)))
  end
  if #list == 1 then
    return cb(entry_of(list[1]))
  end
  self:query().select(list, {
    prompt = 'Select db to assign this buffer to:',
    ---@param r DadbodUI.ConnectionRecord
    ---@return string
    format_item = function(r)
      return r.name
    end,
  }, function(choice)
    cb(entry_of(choice))
  end)
end

--- Jump to (or adopt) the query buffer for the current db context, backing
--- `:DBUIFindBuffer`. A buffer that already carries the `b:dbui_*` contract is
--- registered and revealed in the drawer directly; a bare buffer first resolves a
--- connection (`pick_db`), connects it, and writes the contract before revealing.
--- Opens the drawer, moves the cursor onto the buffer's node, expands its
--- connection, then returns focus to the query window. Port of `db_ui#find_buffer`.
---@return nil
function Drawer:find_buffer()
  local notify = require('dadbod-ui.notifications')
  if #self.instance.dbs_list == 0 then
    return notify.error('No database entries found in DBUI.')
  end
  local key = vim.b.dbui_db_key_name
  local entry = key and self.instance.dbs[key] or nil
  if entry ~= nil then
    return self:reveal_buffer(entry)
  end
  local saved_name = self:query():get_saved_query_db_name()
  self:pick_db(saved_name, function(chosen)
    if chosen == nil then
      return notify.error('No database entries selected or found.')
    end
    self:introspect():connect(chosen)
    notify.info('Assigned buffer to db ' .. chosen.name)
    self:reveal_buffer(chosen)
  end)
end

--- Attach `entry`'s contract to the current buffer (as an existing buffer), then
--- open the drawer, place the cursor on the buffer's node, expand the connection,
--- and hand focus back to the query window. Shared tail of `find_buffer`.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Drawer:reveal_buffer(entry)
  local bufname = vim.api.nvim_buf_get_name(0)
  self:query():setup_buffer(entry, { existing_buffer = true }, bufname)
  -- Feed vim-dadbod-completion when it is installed, mirroring the original.
  if vim.fn.exists('*vim_dadbod_completion#fetch') == 1 then
    pcall(vim.fn['vim_dadbod_completion#fetch'], vim.api.nvim_get_current_buf())
  end
  entry.expanded = true
  entry.buffers.expanded = true
  self:open()
  local row = 0
  for idx, node in ipairs(self.content) do
    if node.type == 'buffer' and node.key_name == entry.key_name and node.file_path == bufname then
      row = idx
      break
    end
  end
  if row > 0 then
    pcall(vim.api.nvim_win_set_cursor, self.winid, { row, 0 })
  end
  -- Back to the window we came from (the query buffer), as the original does.
  vim.cmd('wincmd p')
end

--- Switch the current query buffer from its connection to another one
--- (`:DBUISwitchBuffer`) -- the "oops, wrong connection" verb. Unlike
--- `find_buffer`, which only ASSIGNS a bare buffer and no-ops on an
--- already-attached one, this reassigns a buffer that already carries the
--- contract: it prompts for a different db, re-registers the buffer under it, and
--- rewrites the whole contract (`b:db`, `b:dbui_db_key_name`, the winbar, the
--- execute-on-save autocmds) through the same `setup_buffer` the open path uses.
--- The buffer's text is untouched; the table/schema/bind-param context rides
--- across so a templated query still resolves. A bare buffer is handed to
--- `find_buffer` instead (assign, not switch). Picks always prompt -- switching is
--- an explicit choice -- so a lone connection has nothing to switch to.
---@return nil
function Drawer:switch_buffer()
  local notify = require('dadbod-ui.notifications')
  local bufnr = vim.api.nvim_get_current_buf()
  local key = vim.b[bufnr].dbui_db_key_name
  local current = (type(key) == 'string' and key ~= '') and self.instance.dbs[key] or nil
  if current == nil then
    -- Nothing to switch FROM: fall back to the assign path.
    return self:find_buffer()
  end

  -- Candidates are every OTHER connection; with none there is nothing to switch to.
  local others = vim.tbl_filter(function(r)
    return r.key_name ~= current.key_name
  end, self.instance.dbs_list)
  if #others == 0 then
    return notify.info('No other connection to switch this buffer to.')
  end

  self:query().select(others, {
    prompt = string.format('Switch buffer from %s to db:', current.name),
    ---@param r DadbodUI.ConnectionRecord
    ---@return string
    format_item = function(r)
      return r.name
    end,
  }, function(choice)
    if choice == nil then
      return -- cancelled: leave the buffer on its current connection
    end
    local target = self.instance.dbs[choice.key_name]
    if target == nil or target.key_name == current.key_name then
      return
    end
    -- The async picker may resolve after focus moved (e.g. into the drawer);
    -- re-enter the buffer's window so setup_buffer acts on the right buffer.
    local win = vim.fn.bufwinid(bufnr)
    if win == -1 then
      return notify.error('The query buffer is no longer visible; switch aborted.')
    end
    vim.api.nvim_set_current_win(win)

    -- Carry the buffer's context across (mirrors the rename passthrough): the
    -- text is unchanged, so any {table}/{schema} it was templated with -- and any
    -- answered bind params -- stay valid to re-send against the new connection.
    local carry = {
      existing_buffer = true,
      table = vim.b[bufnr].dbui_table_name,
      schema = vim.b[bufnr].dbui_schema_name,
      bind_params = vim.b[bufnr].dbui_bind_params,
    }
    local bufname = vim.api.nvim_buf_get_name(0)

    -- Drop the buffer from the OLD connection's tracking (setup_buffer re-adds it
    -- to the new one). Filter by resolved path, as remove_buffer does.
    local target_path = vim.fn.fnamemodify(bufname, ':p')
    local function keep(path)
      return vim.fn.fnamemodify(path, ':p') ~= target_path
    end
    current.buffers.list = vim.tbl_filter(keep, current.buffers.list)
    current.buffers.tmp = vim.tbl_filter(keep, current.buffers.tmp)

    -- Connect so b:db is a live handle, then rewrite the contract, re-register,
    -- rewire autocmds and re-apply the winbar -- all through the open path's
    -- setup_buffer (the augroup is per-bufnr and cleared, so nothing leaks).
    self:introspect():connect(target)
    self:query():setup_buffer(target, carry, bufname)

    -- Feed vim-dadbod-completion the new connection, as reveal_buffer does.
    if vim.fn.exists('*vim_dadbod_completion#fetch') == 1 then
      pcall(vim.fn['vim_dadbod_completion#fetch'], bufnr)
    end

    self:render()
    notify.info('Switched buffer to db ' .. target.name)
  end)
end

--- Refresh the tree (`R`): re-discover connections from disk and re-render.
--- A finer-grained per-database refresh arrives with schema introspection.
---@return nil
function Drawer:redraw()
  local item = self:get_current_item()
  if item == nil then
    return
  end
  local notify = require('dadbod-ui.notifications')
  if item.type == 'db' and item.key_name ~= nil then
    local entry = self.instance.dbs[item.key_name]
    notify.info(string.format('Refreshing database %s...', entry and entry.name or ''))
    -- Re-introspect an already-connected database in place; an unconnected one
    -- is left untouched (it introspects on its next expand).
    if entry ~= nil and is_connected(entry) then
      self:introspect():populate(entry)
    end
  else
    notify.info('Refreshing all databases...')
    self.instance:repopulate()
  end
  self:render()
end

--- Move to a sibling at the same tree level. `direction` is
--- 'first' | 'last' | 'next' | 'prev'. Stops at level boundaries and at the
--- top-level separators (level 0 with an empty label).
---@param direction string  'first' | 'last' | 'next' | 'prev'
---@return nil
function Drawer:goto_sibling(direction)
  local line = self:current_line()
  local n = #self.content
  local item = self.content[line]
  if item == nil then
    return
  end
  local level = item.level
  local is_up = direction == 'first' or direction == 'prev'
  local is_down = not is_up
  local is_edge = direction == 'first' or direction == 'last'
  local is_prev_or_next = not is_edge
  local last_same = line

  local idx = line
  while (is_up and idx >= 1) or (is_down and idx <= n) do
    local adj = is_up and idx - 1 or idx + 1
    if adj < 1 or adj > n then
      return
    end
    local adjacent = self.content[adj]
    local on_edge = (is_up and adj == 1) or (is_down and adj == n)
    if adjacent.level == 0 and adjacent.label == '' then
      return self:set_cursor(idx)
    end
    if is_prev_or_next then
      if adjacent.level == level then
        return self:set_cursor(adj)
      end
      if adjacent.level < level then
        return
      end
    end
    if is_edge then
      if adjacent.level == level then
        last_same = adj
      end
      if adjacent.level < level or on_edge then
        return self:set_cursor(last_same)
      end
    end
    idx = adj
  end
end

--- Move to the parent node (level - 1) or the first child (level + 1).
--- A collapsed node is expanded first when descending.
---@param direction string  'parent' | 'child'
---@return nil
function Drawer:goto_node(direction)
  local line = self:current_line()
  local item = self.content[line]
  if item == nil then
    return
  end
  if direction == 'parent' then
    local idx = line
    while idx >= 1 do
      idx = idx - 1
      local adjacent = self.content[idx]
      if adjacent == nil or adjacent.level < item.level then
        break
      end
    end
    return self:set_cursor(idx)
  end
  if item.action ~= 'toggle' then
    return
  end
  if not item.expanded then
    self:toggle_line()
  end
  self:set_cursor(line + 1)
end

return Drawer
