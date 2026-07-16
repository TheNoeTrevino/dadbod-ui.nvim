-- The tree UI (window + content render + interaction)
--
-- A scratch buffer rendered from a real node tree: `drawer/content.lua` builds
-- `roots[]` (nodes with `children`) and flattens it into `content[]` (line N
-- maps to a node, each node carrying `parent`/`index`/`level`). The cursor
-- line indexes `content`; navigation walks the tree.
--
-- The Drawer class is split across this directory: this file owns the window
-- lifecycle, controller accessors, render orchestration, statusline and
-- mappings; `drawer/content.lua` (the pure Node[] builders) and
-- `drawer/actions.lua` (the cursor/interaction verbs) are method mixins merged
-- into the class below; `drawer/paint.lua` is the buffer-touching render half.
--
-- Domain logic is delegated to two acyclic leaf controllers, built lazily and
-- injected with the drawer's backends + a render callback:
--   * `dadbod-ui.introspect` -- connect + schema/table introspection
--     (`self:introspect()`), also owns `load_saved_queries`.
--   * `dadbod-ui.connections_controller` -- interactive connections.json CRUD
--     (`self:connections()`).
-- Neither requires `drawer` or `query`, so `state` stays the dependency sink.
-- The drawer owns the query controller (`self:query()`, lazy require) and
-- reaches into it for `open_buffer`/`focus_window`; the query controller's one
-- back-ref to the drawer is `drawer:render()`.

local constants = require('dadbod-ui.constants')
local icons_mod = require('dadbod-ui.icons')
local bridge = require('dadbod-ui.bridge')
local highlights = require('dadbod-ui.highlights')
local painter = require('dadbod-ui.drawer.paint')
local spinner = require('dadbod-ui.spinner')
local utils = require('dadbod-ui.utils')
local notifications = require('dadbod-ui.notifications')
local state = require('dadbod-ui.state')
local query = require('dadbod-ui.query')
local mappings = require('dadbod-ui.mappings')
local introspect = require('dadbod-ui.introspect')
local ids = require('dadbod-ui.drawer.ids')
local dbout = require('dadbod-ui.dbout')
local connections_controller = require('dadbod-ui.connections_controller')

---@class DadbodUI.DrawerModule
---@field new fun(instance?: DadbodUI.Instance): DadbodUI.Drawer
---@field Drawer DadbodUI.Drawer  the class table
---@field _line_for fun(node: DadbodUI.Node): string  test seam: asserts line_for matches a full paint

---@type DadbodUI.DrawerModule
---@diagnostic disable-next-line: missing-fields
local M = {}

---@class DadbodUI.Drawer
---@field instance DadbodUI.Instance
---@field icons DadbodUI.Icons
---@field config DadbodUI.Config
---@field roots DadbodUI.Node[]  the node tree (navigation walks it)
---@field content DadbodUI.Node[]  flat projection of the tree; line N -> node
--- ALL expand/collapse state, keyed by the stable node ids in `drawer/ids.lua`.
--- Drawer-owned VIEW state: connection entries stay pure domain data. Survives
--- drawer close/reopen (the drawer is a session singleton) and, because the ids
--- are domain-derived, re-introspection can never lose it.
---@field expand table<string, boolean>
---@field help_winid? integer  floating help window id, nil when closed
---@field show_details boolean
---@field input DadbodUI.UiInput  prompt backend (injectable for specs)
---@field confirm DadbodUI.Confirm  yes/no backend (injectable for specs)
---@field connector fun(url: string): string  synchronous connect backend (injectable for specs)
---@field async_connector fun(url: string, on_result: fun(ok: boolean, conn: string)): nil  non-blocking connect backend (injectable for specs)
---@field _painted? DadbodUI.Painted  snapshot of the last paint; diffed by the next render so only the changed span is rewritten (it carries its bufnr, so a recreated buffer invalidates it by construction)
---@field loading_frames table<string, string>  current spinner frame per loading connection (key_name -> frame), rendered by the content builder while `entry.loading`; view state, like `expand`
---@field _query? DadbodUI.Query  lazily-built query controller
---@field _introspect? DadbodUI.Introspect  lazily-built introspection controller
---@field _connections? DadbodUI.ConnectionsController  lazily-built CRUD controller
---@field bufnr? integer
---@field winid? integer
local Drawer = {}
Drawer.__index = Drawer

-- Method mixins: the pure tree builders (drawer/content.lua) and the
-- cursor/interaction verbs (drawer/actions.lua). Their `self` is this same
-- class; merging here keeps `require('dadbod-ui.drawer')` a single Drawer.
for _, mixin in ipairs({ 'dadbod-ui.drawer.content', 'dadbod-ui.drawer.actions' }) do
  for name, method in pairs(require(mixin)) do
    Drawer[name] = method
  end
end

--- Create a drawer over `instance` (defaults to the session singleton).
---@param instance? DadbodUI.Instance
---@return DadbodUI.Drawer
function M.new(instance)
  instance = instance or state.get()
  return setmetatable({
    instance = instance,
    icons = icons_mod.resolve(instance.config),
    config = instance.config,
    roots = {},
    content = {},
    expand = {},
    loading_frames = {},
    help_winid = nil,
    show_details = false,
    input = vim.ui.input,
    confirm = function(msg)
      return notifications.confirm(msg)
    end,
    connector = bridge.connect,
    async_connector = bridge.connect_async,
    _painted = nil,
    _query = nil,
    _introspect = nil,
    _connections = nil,
    bufnr = nil,
    winid = nil,
  }, Drawer)
end

--- The query controller (lazily built; sibling module, required on first use to
--- keep the dependency graph acyclic and startup cheap).
---@return DadbodUI.Query
function Drawer:query()
  if self._query == nil then
    self._query = query.new(self)
  end
  return self._query
end

--- The introspection controller (lazily built): connects connections and folds
--- their schemas/tables into the entries, re-rendering when async data lands. It
--- captures the drawer's injectable connect backend and a render callback, but
--- requires neither `drawer` nor `query`, keeping the graph acyclic.
---@return DadbodUI.Introspect
function Drawer:introspect()
  if self._introspect == nil then
    self._introspect = introspect.new({
      config = self.config,
      connector = self.connector,
      async_connector = self.async_connector,
      render = function()
        self:render()
      end,
      repaint = function(key_name, frame)
        self:repaint_db_node(key_name, frame)
      end,
    })
  end
  return self._introspect
end

--- The connections CRUD controller (lazily built): wires the interactive add/
--- rename/duplicate/group/delete flows over connections.json. It captures the
--- drawer's injectable input/confirm backends and a render callback, but requires
--- neither `drawer` nor `query`.
---@return DadbodUI.ConnectionsController
function Drawer:connections()
  if self._connections == nil then
    self._connections = connections_controller.new({
      instance = self.instance,
      input = self.input,
      confirm = self.confirm,
      render = function()
        self:render()
      end,
    })
  end
  return self._connections
end

--- Whether the node identified by `id` (see `drawer/ids.lua`) is expanded.
--- `default` is the state before the user ever touched the node (group nodes
--- pass `config.drawer.expand_groups`; everything else starts collapsed).
---@param id string
---@param default? boolean
---@return boolean
function Drawer:is_expanded(id, default)
  local value = self.expand[id]
  if value == nil then
    return default == true
  end
  return value
end

--- Record expand state for the node identified by `id`.
---@param id string
---@param value boolean
---@return nil
function Drawer:set_expanded(id, value)
  self.expand[id] = value
end

--- Mark a connection's section expanded -- the semantic verb for callers
--- outside the drawer (e.g. the query controller pre-expanding Buffers), so the
--- id scheme in `drawer/ids.lua` stays a drawer-internal detail.
---@param key_name string
---@param section string  'buffers' | 'saved_queries' | 'schemas' | 'tables' | 'routines'
---@return nil
function Drawer:expand_section(key_name, section)
  self:set_expanded(ids.section(key_name, section), true)
end

---@return boolean
function Drawer:is_open()
  return self.winid ~= nil and vim.api.nvim_win_is_valid(self.winid)
end

--- Open the drawer window, or focus it if already open.
---@param mods? string  command modifiers (e.g. 'tab')
---@return DadbodUI.Drawer
function Drawer:open(mods)
  if self:is_open() then
    vim.api.nvim_set_current_win(self.winid)
    return self
  end
  local side = self.config.drawer.position == 'right' and 'botright' or 'topleft'
  -- Open the split WITHOUT `silent!` and under pcall: a swallowed failure (e.g.
  -- E36 "not enough room" on a narrow terminal) would leave us in the user's
  -- ORIGINAL window/buffer, which we would then convert to a scratch drawer and
  -- overwrite with render() -- destroying their buffer. Capture the pre-split
  -- window/buffer and verify the split actually produced a *fresh* window before
  -- mutating anything; on failure notify and bail without touching the user's UI.
  local prev_win = vim.api.nvim_get_current_win()
  local prev_buf = vim.api.nvim_get_current_buf()
  local ok = pcall(vim.cmd, string.format('%s vertical %s %dnew', mods or '', side, self.config.drawer.width))
  local win = vim.api.nvim_get_current_win()
  if not ok or win == prev_win or vim.api.nvim_get_current_buf() == prev_buf then
    notifications.error('Could not open the ' .. constants.name .. ' drawer window (no room to split).')
    return self
  end
  self.winid = win
  self.bufnr = vim.api.nvim_get_current_buf()

  local bo = vim.bo[self.bufnr]
  bo.buftype = 'nofile'
  bo.bufhidden = 'wipe'
  bo.buflisted = false
  bo.swapfile = false
  local wo = vim.wo[self.winid]
  wo.wrap = false
  wo.number = false
  wo.relativenumber = false
  wo.spell = false
  wo.list = false
  wo.signcolumn = 'no'
  wo.winfixwidth = true

  self:setup_mappings()
  -- Define the drawer highlight groups (idempotent, default-linked so user
  -- overrides win) before the first paint.
  highlights.define()
  -- Register the dbout filetype / result-recording autocmds and the loading
  -- spinner on dadbod's async execute events (idempotent across opens).
  dbout.attach(self)
  vim.api.nvim_create_autocmd('BufEnter', {
    buffer = self.bufnr,
    callback = function()
      self:render()
    end,
  })
  self:render()
  bo.filetype = constants.drawer_filetype
  -- Signal that the drawer opened so users can hook it (`autocmd User DBUIOpened`).
  -- We fire only on a real open, not when `open()` focuses an already-open drawer
  -- (the early return above), so this stays a one-shot open event.
  vim.api.nvim_exec_autocmds('User', { pattern = constants.drawer_opened_event })
  return self
end

---@return nil
function Drawer:close()
  -- Stop any in-flight db loading animations (keyed by entry key_name) so closing
  -- the drawer mid-load never leaks a timer or repaints a wiped buffer. dbout's
  -- result-buffer spinners are keyed by file path, so they are untouched.
  for key_name, entry in pairs(self.instance.dbs) do
    spinner.stop(key_name)
    entry.loading = false
  end
  if self:is_open() then
    -- pcall: closing the drawer when it is the only window raises E444; there is
    -- nothing to fall back to, so degrade gracefully rather than crash the caller.
    pcall(vim.api.nvim_win_close, self.winid, true)
  end
  self.winid = nil
  self.bufnr = nil
end

Drawer.quit = Drawer.close

---@return nil
function Drawer:toggle()
  if self:is_open() then
    self:close()
  else
    self:open()
  end
end

--- Rebuild `content` from the instance and write the buffer lines. Incremental:
--- the paint diffs against the previous render's snapshot and rewrites only the
--- changed span, so an unchanged render (e.g. the BufEnter re-render) leaves the
--- buffer, its extmarks and the cursor untouched.
---@return DadbodUI.Drawer
function Drawer:render()
  if not self:is_open() then
    return self
  end
  -- is_open() guarantees a live window, hence a buffer; narrow bufnr to non-nil.
  local bufnr = assert(self.bufnr)
  self._painted = painter.paint(bufnr, self:build_content(), self.icons, self._painted)
  return self
end

--- Advance the loading spinner on `key_name`'s db node -- the 80ms tick the
--- introspect controller drives. Records the frame the content builder renders
--- for a loading entry (appended after the label, so the fold icon + name stay
--- fixed while only the trailer animates) and re-renders: the incremental paint
--- rewrites exactly the one changed line, so no second buffer-writing path has
--- to reproduce `paint`'s output byte-for-byte. Once the `loading` marker
--- clears, the frame simply stops being rendered.
---@param key_name string
---@param frame string
---@return nil
function Drawer:repaint_db_node(key_name, frame)
  self.loading_frames[key_name] = frame
  self:render()
end

--- Connection/table info for the current buffer, for embedding in a `statusline`
--- or `winbar`. A query buffer renders `<prefix><db_name><sep><schema><sep><table>`
--- from the `b:dbui_*` contract, keeping only the requested, non-empty fields; a
--- `.dbout` result buffer renders `Last query time: <t> sec.` when a runtime is
--- known. Returns `''` for any other buffer, so it stays inert in unrelated
--- windows.
---@param opts? DadbodUI.StatuslineOpts
---@return string
function Drawer:statusline(opts)
  opts = opts or {}
  local key_name = vim.b.dbui_db_key_name or ''
  local is_dbout = vim.bo.filetype == 'dbout'
  if not is_dbout and key_name == '' then
    return ''
  end
  if is_dbout then
    local time = self:query():get_last_query_info().last_query_time
    return time ~= '' and ('Last query time: ' .. time .. ' sec.') or ''
  end
  local entry = self.instance.dbs[key_name]
  if entry == nil then
    return ''
  end
  ---@type table<string, string>
  local data = {
    db_name = entry.name,
    schema = vim.b.dbui_schema_name or '',
    table = vim.b.dbui_table_name or '',
  }
  -- Embedded in `statusline`/`winbar`, so this runs on every redraw; a plain loop
  -- over the (<=3) shown fields avoids allocating an iterator and closures per tick.
  local parts = {}
  for _, field in ipairs(opts.show or { 'db_name', 'schema', 'table' }) do
    local value = data[field]
    if value ~= nil and value ~= '' then
      parts[#parts + 1] = value
    end
  end
  return (opts.prefix or constants.statusline_prefix) .. table.concat(parts, opts.separator or ' -> ')
end

--- The drawer's built-in action handlers, keyed by the ids in
--- `config.builtin_actions.drawer`. `setup_mappings` binds each to whichever
--- `lhs` names it in `config.drawer.keys`; the same ids drive the help window.
---@return table<string, fun()>
function Drawer:drawer_handlers()
  return {
    help = function()
      self:toggle_help()
    end,
    toggle = function()
      self:toggle_line()
    end,
    toggle_split = function()
      local pos = utils.opposite_position(self.config.drawer.position)
      self:toggle_line('vertical ' .. pos .. ' split')
    end,
    quit = function()
      self:quit()
    end,
    add_connection = function()
      self:connections():add_connection()
    end,
    delete = function()
      self:delete_line()
    end,
    rename = function()
      self:rename_line()
    end,
    redraw = function()
      self:redraw()
    end,
    duplicate = function()
      self:duplicate_line()
    end,
    set_group = function()
      self:set_group_line()
    end,
    move_up = function()
      self:move_line('up')
    end,
    move_down = function()
      self:move_line('down')
    end,
    toggle_details = function()
      self:toggle_details()
    end,
    first_sibling = function()
      self:goto_sibling('first')
    end,
    last_sibling = function()
      self:goto_sibling('last')
    end,
    prev_sibling = function()
      self:goto_sibling('prev')
    end,
    next_sibling = function()
      self:goto_sibling('next')
    end,
    goto_parent = function()
      self:goto_node('parent')
    end,
    goto_child = function()
      self:goto_node('child')
    end,
  }
end

---@return nil
function Drawer:setup_mappings()
  local opts = { buffer = self.bufnr, nowait = true, silent = true }
  -- User actions get the node under the cursor + its connection (resolved lazily
  -- at trigger time, not bind time).
  local function make_ctx(mode)
    local item = self:get_current_item()
    local conn = item and item.key_name and self.instance.dbs[item.key_name] or nil
    return { mode = mode, bufnr = self.bufnr, drawer = self, item = item, connection = conn }
  end
  mappings.apply(self.config.drawer.keys, self:drawer_handlers(), self.config.actions, make_ctx, opts)
end

-- Exposed for the line-render spec (asserts line_for matches a full paint).
M._line_for = painter.line_for

M.Drawer = Drawer
return M
