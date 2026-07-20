-- Cursor/interaction verbs on the drawer tree
--
-- A method mixin merged into `DadbodUI.Drawer` by `drawer/init.lua`: the node
-- under the cursor is resolved via `get_current_item` and acted on -- toggles,
-- opens, the interactive connection CRUD dispatchers, buffer rename/delete,
-- find/reveal, and sibling/parent navigation.

local constants = require('dadbod-ui.constants')
local float = require('dadbod-ui.float')
local bridge = require('dadbod-ui.bridge')
local ids = require('dadbod-ui.drawer.ids')
local utils = require('dadbod-ui.utils')
local notify = require('dadbod-ui.notifications')
local state = require('dadbod-ui.state')
local mappings = require('dadbod-ui.mappings')

---@private
-- The connected predicate lives in state (the SSOT); required lazily here to
-- keep the dependency graph acyclic, mirroring the lazy state require in M.new.
---@param entry DadbodUI.ConnectionEntry
---@return boolean
local function is_connected(entry)
  return state.is_connected(entry)
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

  -- Built from each context's `keys` map so the help window and the live keymaps
  -- can never drift; disabled (`false`) keys are already filtered out.
  self.help_winid = float.open(mappings.help_lines(self.config), {
    title = 'Help',
    close_keys = { 'q', '<Esc>', '?' },
    on_close = function()
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

--- Refresh `entry.saved_queries` from disk. Thin wrapper over the
--- introspection controller (which owns it so the query controller can refresh
--- saved queries without a drawer back-ref), exposed here for the drawer's own
--- callers and the saved-query specs.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Drawer:load_saved_queries(entry)
  return self:introspect():load_saved_queries(entry)
end

--- The window the cursor verbs should act through. The drawer buffer can be
--- shown in more than one window (a user `<C-w>s`), and the sidebar mappings are
--- buffer-local, so they fire from whichever window holds focus. Resolving to
--- `self.winid` there would read/move the OTHER window's cursor; use the current
--- window when it is showing the drawer buffer, else fall back to `self.winid`.
---@return integer
function Drawer:active_winid()
  local cur = vim.api.nvim_get_current_win()
  if self.bufnr ~= nil and vim.api.nvim_win_get_buf(cur) == self.bufnr then
    return cur
  end
  return self.winid
end

---@return integer
function Drawer:current_line()
  return vim.api.nvim_win_get_cursor(self:active_winid())[1]
end

---@param line integer
function Drawer:set_cursor(line)
  line = math.max(1, math.min(line, #self.content))
  local winid = self:active_winid()
  local col = vim.api.nvim_win_get_cursor(winid)[2]
  vim.api.nvim_win_set_cursor(winid, { line, col })
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
-- One owner: the DRAWER holds all view state -- `help_winid`, `show_details`
-- and the `expand` map (every expand/collapse flag, keyed by the stable node
-- ids in `drawer/ids.lua`). Connection entries are pure domain data; nothing
-- in `state.lua` knows what the tree looks like. A toggle is one generic map
-- flip; per-node side effects ride on the node as `on_expand`/`on_collapse`/
-- `on_activate` callbacks set at build time, so this dispatcher never grows
-- type branches.

--- Act on the node under the cursor. Runs `activate` callbacks; opens query,
--- buffer, saved-query and table-helper nodes through the query controller (in
--- `edit_action`, defaulting to `edit`); previews dbout result files; flips
--- toggle nodes.
---@param edit_action? string  'edit' | 'vertical … split' (default 'edit')
---@return DadbodUI.Drawer|nil
function Drawer:toggle_line(edit_action)
  local item = self:get_current_item()
  if item == nil or item.action == 'noaction' then
    return
  end
  if item.on_activate ~= nil then
    return item.on_activate()
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
  -- Generic flip (see the ownership note above): `item.expanded` is the state
  -- the node was BUILT with, so its negation is the new state. `on_expand`
  -- fires only on the opening flip, `on_collapse` only on the closing one.
  if item.id ~= nil then
    local opening = not item.expanded
    self:set_expanded(item.id, opening)
    if opening then
      if item.on_expand ~= nil then
        item.on_expand()
      end
    elseif item.on_collapse ~= nil then
      item.on_collapse()
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

--- Color the connection or group under the cursor (`C`): a db line prompts for
--- the connection's own color, a group line for the group's (issue #91). Empty
--- input clears; anything else must be `#rrggbb`.
---@return nil
function Drawer:set_color_line()
  local item = self:get_current_item()
  if item == nil then
    return
  end
  if item.type == 'db' then
    return self:connections():set_connection_color(self.instance.dbs[item.key_name])
  end
  if item.type == 'group' and item.group ~= nil then
    return self:connections():set_group_color(item.group)
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
  for _, entry in ipairs(self.instance.dbs_list) do
    if entry.name:lower() == name:lower() and bridge.resolve(entry.url):lower() == resolved then
      target_group = entry.group or ''
      for idx, node in ipairs(self.content) do
        if node.type == 'db' and node.key_name == entry.key_name then
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
      return notify.error('Cannot delete this connection.')
    end
    return self:connections():delete_connection(entry)
  end
  if item.action == 'open' and (item.type == 'buffer' or item.type == 'saved_query') then
    return self:delete_buffer(item)
  end
end

--- Delete a saved query or tmp query buffer (the file and all its tracking),
--- after confirmation. Saved queries leave file connections' disk store; tmp
--- buffers only exist in the tmp location.
---@param item DadbodUI.Node
---@return nil
function Drawer:delete_buffer(item)
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
    pcall(vim.fs.rm, file)
    entry.saved_queries = drop(entry.saved_queries)
    entry.buffers = drop(entry.buffers)
    notify.info('Deleted.')
  elseif self.instance:is_tmp_location_buffer(file) then
    if not self.confirm('Are you sure you want to delete query?') then
      return
    end
    pcall(vim.fs.rm, file)
    entry.buffers = drop(entry.buffers)
    notify.info('Deleted.')
  else
    return
  end
  local bufnr = utils.loaded_bufnr(file)
  if bufnr > -1 then
    local win = vim.fn.bufwinid(bufnr)
    if win > -1 then
      vim.api.nvim_set_current_win(win)
      vim.cmd('silent! b#')
    end
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
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
    return self:rename_buffer(item.file_path, item.key_name)
  end
  if item.type == 'db' then
    return self:connections():rename_connection(self.instance.dbs[item.key_name])
  end
end

--- Rename a written query file on disk and move its buffer tracking to the new
--- name, transferring the buffer-local contract. The file stays in its directory
--- (which records the owning connection), so the new name is used as-is.
--- Callback-shaped for our async prompt backend.
---@param buffer string  the file being renamed
---@param key_name string  the owning connection's key
---@return nil
function Drawer:rename_buffer(buffer, key_name)
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
  self.input({ prompt = 'Enter new name: ', default = vim.fs.basename(buffer) }, function(new_name)
    if new_name == nil then
      return
    end
    new_name = vim.trim(new_name)
    if new_name == '' then
      return notify.error('Valid name must be provided.')
    end
    local dir = vim.fn.fnamemodify(buffer, ':p:h')
    local new = string.format('%s/%s', dir, new_name)
    -- Refuse to silently clobber an existing file at the target path.
    if utils.is_file(new) then
      return notify.error('A query already exists with that name.')
    end
    -- rename() returns 0 on success; on failure (read-only dir, invalid name) bail
    -- BEFORE mutating any tracking, or the file would vanish from the drawer while
    -- still on disk.
    if vim.fn.rename(buffer, new) ~= 0 then
      return notify.error('Could not rename the query file.')
    end

    -- loaded_bufnr, not vim.fn.bufnr: the path is looked up exactly, never as a
    -- name PATTERN (a `.` in the path would otherwise match any char).
    local bufnr = utils.loaded_bufnr(buffer)
    local bufwin = bufnr > -1 and vim.fn.bufwinid(bufnr) or -1
    local new_bufnr = -1
    if bufwin > -1 then
      -- Navigate to the window actually showing the old buffer first: open_buffer
      -- -> Query:focus_window picks the first dbui window, which could be a
      -- DIFFERENT window's query buffer, and the rename would replace it.
      vim.api.nvim_set_current_win(bufwin)
      self:query():open_buffer(entry, new, 'edit')
      new_bufnr = vim.api.nvim_get_current_buf()
    elseif bufnr > -1 then
      -- bufadd() returns the buffer number for `new` directly (creating it if
      -- needed), so we never round-trip through vim.fn.bufnr's pattern matching.
      new_bufnr = vim.fn.bufadd(new)
      vim.bo[new_bufnr].buflisted = true
      table.insert(entry.buffers, new)
    else
      local idx = vim.fn.index(entry.buffers, buffer)
      if idx > -1 then
        table.insert(entry.buffers, idx + 1, new)
      end
    end
    entry.buffers = vim.tbl_filter(function(v)
      return v ~= buffer
    end, entry.buffers)

    if new_bufnr > -1 then
      -- Carry the contract onto the renamed buffer through the single writer,
      -- preserving the old buffer's table name and bind params (the latter is
      -- nil when the source was never parametrized -- write_contract skips it).
      local old = vim.b[bufnr]
      self:query().write_contract(new_bufnr, entry, {
        table = old.dbui_table_name,
        schema = old.dbui_schema_name,
        bind_params = old.dbui_bind_params,
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
--- yet, then hand it to `cb`. A buffer inside a connection's tmp or save folder
--- already names its owner (the folder is the ownership record --
--- `instance:entry_for_dir`); otherwise a lone connection is taken automatically
--- and several prompt the (injectable) selector. `cb` receives the entry, or nil
--- when nothing resolves or the user cancels. Callback-shaped for the async
--- selector.
---@param cb fun(entry: DadbodUI.ConnectionEntry|nil)
---@return nil
function Drawer:pick_db(cb)
  local owner = self.instance:entry_for_dir(vim.fn.expand('%:p:h'))
  if owner ~= nil then
    return cb(owner)
  end
  local list = self.instance.dbs_list
  if #list == 0 then
    return cb(nil)
  end
  if #list == 1 then
    return cb(list[1])
  end
  self:query().select(list, {
    prompt = 'Select db to assign this buffer to:',
    ---@param entry DadbodUI.ConnectionEntry
    ---@return string
    format_item = function(entry)
      return entry.name
    end,
  }, cb)
end

--- Jump to (or adopt) the query buffer for the current db context, backing
--- `api.buf.find`. A buffer that already carries the `b:dbui_*` contract is
--- registered and revealed in the drawer directly; a bare buffer first resolves a
--- connection (`pick_db`), connects it, and writes the contract before revealing.
--- Opens the drawer, moves the cursor onto the buffer's node, expands its
--- connection, then returns focus to the query window.
---@return nil
function Drawer:find_buffer()
  if #self.instance.dbs_list == 0 then
    return notify.error('No database entries found in ' .. constants.name .. '.')
  end
  local key = vim.b.dbui_db_key_name
  local entry = key and self.instance.dbs[key] or nil
  if entry ~= nil then
    return self:reveal_buffer(entry)
  end
  self:pick_db(function(chosen)
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
  -- Refuse an unnamed buffer: adopting it would insert '' into entry.buffers
  -- and render a phantom empty node in the drawer.
  if bufname == '' then
    return notify.error('Cannot assign an unnamed buffer; save it to a file first.')
  end
  self:query():setup_buffer(entry, { existing_buffer = true }, bufname)
  -- Feed vim-dadbod-completion when it is installed.
  if vim.fn.exists('*vim_dadbod_completion#fetch') == 1 then
    pcall(vim.fn['vim_dadbod_completion#fetch'], vim.api.nvim_get_current_buf())
  end
  self:set_expanded(ids.db(entry.key_name), true)
  self:expand_section(entry.key_name, 'buffers')
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
  -- Back to the window we came from (the query buffer).
  vim.cmd('wincmd p')
end

--- Open the drawer, expand the connection `key_name` (introspecting it lazily,
--- exactly as clicking its node would), and place the cursor on it. The scriptable
--- "show me this database" verb behind `dadbod-ui.api.reveal`. Best-effort: a no-op
--- for an unknown key. Returns focus to the drawer window (unlike `reveal_buffer`,
--- which is called from a query buffer and hands focus back).
---@param key_name string
---@return nil
function Drawer:reveal_db(key_name)
  local entry = self.instance.dbs[key_name]
  if entry == nil then
    return
  end
  self:open()
  if self:is_expanded(ids.db(key_name)) then
    self:render()
  else
    -- Mark expanded and run the SAME lazy introspection the toggle path fires.
    self:set_expanded(ids.db(key_name), true)
    self:introspect():expand_db(entry)
  end
  self:focus_db(key_name)
end

--- Re-introspect the connection `key_name`: reload its saved queries and re-scan
--- schemas/tables from the live database (connecting first if needed), re-rendering
--- the drawer when open. Backs `dadbod-ui.api.refresh`. Reuses the expand path, so
--- an already-connected db just repopulates. A no-op for an unknown key.
---@param key_name string
---@return nil
function Drawer:refresh_db(key_name)
  local entry = self.instance.dbs[key_name]
  if entry == nil then
    return
  end
  self:introspect():expand_db(entry)
end

--- Switch the current query buffer from its connection to another one
--- (`api.buf.switch`) -- the "oops, wrong connection" verb. Unlike
--- `find_buffer`, which only ASSIGNS a bare buffer and no-ops on an
--- already-attached one, this reassigns a buffer that already carries the
--- contract: it prompts for a different db, re-registers the buffer under it, and
--- rewrites the whole contract (`b:db`, `b:dbui_db_key_name`, the winbar, the
--- execute-on-save autocmds) through the same `setup_buffer` the open path uses.
--- The buffer's text is untouched; the table/schema/bind-param context rides
--- across so a templated query still resolves. A bare buffer is handed to
--- `find_buffer` instead (assign, not switch). Picks always prompt -- switching is
--- an explicit choice -- so a lone connection has nothing to switch to.
---
--- `target_name` (name or key_name) switches DIRECTLY to that connection with no
--- prompt -- the scriptable path behind `dadbod-ui.api.buf.switch`. It returns
--- `ok, err`; the interactive path (no `target_name`) shows the picker and
--- returns nil.
---@param target_name? string
---@return boolean|nil ok
---@return string|nil err
function Drawer:switch_buffer(target_name)
  local bufnr = vim.api.nvim_get_current_buf()
  local key = vim.b[bufnr].dbui_db_key_name
  local current = (type(key) == 'string' and key ~= '') and self.instance.dbs[key] or nil
  if current == nil then
    -- Nothing to switch FROM. The interactive verb falls back to the assign
    -- path; a scripted switch to a named db needs a real query buffer, so error.
    if target_name ~= nil then
      return false, 'the current buffer is not a dadbod-ui query buffer'
    end
    return self:find_buffer()
  end

  -- Candidates are every OTHER connection; with none there is nothing to switch to.
  local others = vim.tbl_filter(function(r)
    return r.key_name ~= current.key_name
  end, self.instance.dbs_list)
  -- Sorted by their `group/name` label so the picker reads predictably.
  table.sort(others, function(a, b)
    return utils.display_name(a.name, a.group):lower() < utils.display_name(b.name, b.group):lower()
  end)
  if #others == 0 then
    if target_name ~= nil then
      return false, 'no other connection to switch this buffer to'
    end
    return notify.info('No other connection to switch this buffer to.')
  end

  -- The switch core: reassign the captured `bufnr` to the chosen connection --
  -- always a member of `others`, so never `current` itself. Shared by the picker
  -- callback and the direct (scripted) path. Returns `ok, err`.
  ---@param target DadbodUI.ConnectionEntry
  ---@return boolean ok
  ---@return string|nil err
  local function do_switch(target)
    -- The async picker may resolve after focus moved (e.g. into the drawer);
    -- re-enter the buffer's window so setup_buffer acts on the right buffer.
    local win = vim.fn.bufwinid(bufnr)
    if win == -1 then
      notify.error('The query buffer is no longer visible; switch aborted.')
      return false, 'the query buffer is no longer visible'
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
    local function keep(path)
      return not utils.same_path(path, bufname)
    end
    current.buffers = vim.tbl_filter(keep, current.buffers)

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
    return true
  end

  -- Direct path: resolve `target_name` among the candidates and switch, no prompt.
  if target_name ~= nil then
    local choice = vim.iter(others):find(function(r)
      return r.name == target_name or r.key_name == target_name
    end)
    if choice == nil then
      return false, 'no connection named ' .. target_name .. ' to switch to'
    end
    return do_switch(choice)
  end

  self:query().select(others, {
    -- Label candidates (and the current db) as `group/name` so a name reused
    -- across groups is unambiguous in the picker -- see issue #58.
    prompt = string.format('Switch buffer from %s to db:', utils.display_name(current.name, current.group)),
    ---@param r DadbodUI.ConnectionEntry
    ---@return string
    format_item = function(r)
      return utils.display_name(r.name, r.group)
    end,
  }, function(choice)
    if choice == nil then
      return -- cancelled: leave the buffer on its current connection
    end
    do_switch(choice)
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

--- Move to a sibling: another child of the same parent (top-level nodes are
--- siblings of every other top-level node). `direction` is
--- 'first' | 'last' | 'next' | 'prev'. Hint/separator chrome is skipped, never
--- landed on.
---@param direction string  'first' | 'last' | 'next' | 'prev'
---@return nil
function Drawer:goto_sibling(direction)
  local item = self:get_current_item()
  if item == nil then
    return
  end
  local all = item.parent ~= nil and item.parent.children or self.roots
  ---@type DadbodUI.Node[]
  local siblings = {}
  local pos
  for _, node in ipairs(all) do
    if node.action ~= 'noaction' then
      siblings[#siblings + 1] = node
      if node == item then
        pos = #siblings
      end
    end
  end
  if pos == nil then
    return -- the cursor sits on chrome; nowhere sensible to move
  end
  local target
  if direction == 'first' then
    target = siblings[1]
  elseif direction == 'last' then
    target = siblings[#siblings]
  elseif direction == 'prev' then
    target = siblings[pos - 1]
  else
    target = siblings[pos + 1]
  end
  if target ~= nil and target ~= item then
    self:set_cursor(target.index)
  end
end

--- Move to the parent node or the first child. A collapsed node is expanded
--- first when descending.
---@param direction string  'parent' | 'child'
---@return nil
function Drawer:goto_node(direction)
  local item = self:get_current_item()
  if item == nil then
    return
  end
  if direction == 'parent' then
    -- A top-level node has no parent: no-op (never clamp onto line 1).
    if item.parent ~= nil then
      self:set_cursor(item.parent.index)
    end
    return
  end
  if item.action ~= 'toggle' then
    return
  end
  if not item.expanded then
    -- Expanding re-renders (rebuilding every node), so re-resolve the node at
    -- the same line before reading its children.
    self:toggle_line()
    item = self.content[item.index]
    if item == nil then
      return
    end
  end
  local child = item.children ~= nil and item.children[1] or nil
  if child ~= nil then
    self:set_cursor(child.index)
  end
end

return Drawer
