---@mod dadbod-ui.drawer  The tree UI (window + content render + interaction)
---
--- A scratch buffer whose lines are built from a `content[]` array where line N
--- maps to a node. The cursor line indexes `content` to find the node and its
--- action.
---
--- Domain logic is delegated to two acyclic leaf controllers, built lazily and
--- injected with the drawer's backends + a render callback:
---   * `dadbod-ui.introspect` -- connect + schema/table introspection
---     (`self:introspect()`), also owns `load_saved_queries`.
---   * `dadbod-ui.connections_controller` -- interactive connections.json CRUD
---     (`self:connections()`).
--- Neither requires `drawer` or `query`, so `state` stays the dependency sink.
--- The drawer owns the query controller (`self:query()`, lazy require) and
--- reaches into it for `open_buffer`/`focus_window`; the query controller's one
--- back-ref to the drawer is `drawer:render()`.

local icons_mod = require('dadbod-ui.icons')
local bridge = require('dadbod-ui.bridge')
local highlights = require('dadbod-ui.highlights')
local spinner = require('dadbod-ui.spinner')
local spinners = require('dadbod-ui.spinners')
local utils = require('dadbod-ui.utils')

local INDENT = 2

-- The connected predicate lives in state (the SSOT); required lazily here to
-- keep the dependency graph acyclic, mirroring the lazy state require in M.new.
---@param entry DadbodUI.ConnectionEntry
---@return boolean
local function is_connected(entry)
  return require('dadbod-ui.state').is_connected(entry)
end

local HELP_LINES = {
  '" o - Open/Toggle selected item',
  '" S - Open/Toggle selected item in vertical split',
  '" d - Delete selected item',
  '" R - Redraw',
  '" A - Add connection',
  '" D - Duplicate connection',
  '" G - Add/remove connection to a group',
  '" H - Toggle database details',
  '" r - Rename/Edit buffer/connection/saved query',
  '" q - Close drawer',
  '" <C-j>/<C-k> - Go to last/first sibling',
  '" K/J - Go to prev/next sibling',
  '" <C-p>/<C-n> - Go to parent/child node',
  '" <Leader>W - (sql) Save currently opened query',
  '" <Leader>S - (sql) Execute query in visual or normal mode',
}

local M = {}

---@class DadbodUI.Drawer
---@field instance DadbodUI.Instance
---@field icons DadbodUI.Icons
---@field config DadbodUI.Config
---@field content DadbodUI.Node[]  line N -> node
--- Drawer-owned transient VIEW state (group expand + the show_* flags below);
--- entries own DOMAIN expand. See the ownership note above `toggle_line`.
---@field groups table<string, { expanded: boolean }>  per-group expand state
---@field show_help boolean
---@field show_details boolean
---@field input DadbodUI.UiInput  prompt backend (injectable for specs)
---@field confirm DadbodUI.Confirm  yes/no backend (injectable for specs)
---@field connector fun(url: string): string  connect backend (injectable for specs)
---@field show_dbout_list boolean  whether the Query results section is expanded
---@field _query? DadbodUI.Query  lazily-built query controller
---@field _introspect? DadbodUI.Introspect  lazily-built introspection controller
---@field _connections? DadbodUI.ConnectionsController  lazily-built CRUD controller
---@field bufnr? integer
---@field winid? integer
local Drawer = {}
Drawer.__index = Drawer

--- Create a drawer over `instance` (defaults to the session singleton).
---@param instance? DadbodUI.Instance
---@return DadbodUI.Drawer
function M.new(instance)
  instance = instance or require('dadbod-ui.state').get()
  return setmetatable({
    instance = instance,
    icons = icons_mod.resolve(instance.config),
    config = instance.config,
    content = {},
    groups = {},
    show_help = false,
    show_details = false,
    input = vim.ui.input,
    confirm = function(msg)
      return require('dadbod-ui.notifications').confirm(msg)
    end,
    connector = bridge.connect,
    show_dbout_list = false,
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
    self._query = require('dadbod-ui.query').new(self)
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
    self._introspect = require('dadbod-ui.introspect').new({
      config = self.config,
      connector = self.connector,
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
    self._connections = require('dadbod-ui.connections_controller').new({
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

---@param name string
---@return { expanded: boolean }
function Drawer:group_state(name)
  if self.groups[name] == nil then
    self.groups[name] = { expanded = self.config.expand_groups }
  end
  return self.groups[name]
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
  local side = self.config.win_position == 'right' and 'botright' or 'topleft'
  vim.cmd(string.format('silent! %s vertical %s %dnew', mods or '', side, self.config.winwidth))
  self.winid = vim.api.nvim_get_current_win()
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
  require('dadbod-ui.dbout').attach(self)
  vim.api.nvim_create_autocmd('BufEnter', {
    buffer = self.bufnr,
    callback = function()
      self:render()
    end,
  })
  self:render()
  bo.filetype = 'dbui'
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
    vim.api.nvim_win_close(self.winid, true)
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

---@param node DadbodUI.Node
function Drawer:add(node)
  self.content[#self.content + 1] = node
end

---@param kind string
---@param expanded boolean
---@return string
function Drawer:toggle_icon(kind, expanded)
  return expanded and self.icons.expanded[kind] or self.icons.collapsed[kind]
end

--- Rebuild the drawer node list from the instance, storing it on `self.content`
--- (navigation indexes that field) and returning it. Pure with respect to the
--- window: it needs no open drawer, which makes it unit-testable on its own.
---@return DadbodUI.Node[]
function Drawer:build_content()
  self.content = {}
  self:render_help()
  self:render_dbs()
  if #self.instance.dbs_list == 0 then
    self:add({ label = '" No connections', icon = '', level = 0, type = 'help', action = 'noaction' })
    self:add({ label = 'Add connection', icon = self.icons.add_connection, level = 0, type = 'add_connection', action = 'call_method' })
  end
  self:render_dbout_list()
  return self.content
end

--- The display string for a single node: indent + icon + separator + label. The
--- single source of truth for a rendered line, shared by the full `paint` and
--- the targeted `repaint_db_node` so an animated spinner frame lands identically
--- to a full render. Standalone (no `self`).
---@param node DadbodUI.Node
---@return string
local function line_for(node)
  local indent = string.rep(' ', INDENT * node.level)
  local sep = node.icon ~= '' and ' ' or ''
  local trailer = node.loading_frame and (' ' .. node.loading_frame) or ''
  return indent .. node.icon .. sep .. node.label .. trailer
end

--- Paint a node list into `bufnr`: map each node to its display string (via
--- `line_for`), overwrite the buffer under a `modifiable` toggle, then re-apply
--- the per-node highlights as extmarks in the `dadbod_ui` namespace (cleared
--- first). The only render half that requires a buffer; the highlight ranges come
--- from the pure `highlights.highlights_for`, mirroring the `build_content`/
--- `paint` purity split. Standalone (no `self`) so the paint seam stays decoupled
--- from instance state; `icons` is threaded in for the connection ok/error glyph
--- lookup.
---@param bufnr integer
---@param nodes DadbodUI.Node[]
---@param icons DadbodUI.Icons
---@return nil
local function paint(bufnr, nodes, icons)
  local lines = {}
  ---@type DadbodUI.Highlight[][]
  local line_hls = {}
  for i, node in ipairs(nodes) do
    local text = line_for(node)
    lines[i] = text
    line_hls[i] = highlights.highlights_for(node, text, icons)
  end

  local bo = vim.bo[bufnr]
  bo.modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  bo.modifiable = false

  vim.api.nvim_buf_clear_namespace(bufnr, highlights.NS, 0, -1)
  for i, hls in ipairs(line_hls) do
    for _, hl in ipairs(hls) do
      vim.api.nvim_buf_set_extmark(bufnr, highlights.NS, i - 1, hl.col_start, {
        end_col = hl.col_end,
        hl_group = hl.group,
      })
    end
  end
end

--- Rebuild `content` from the instance and write the buffer lines.
---@return DadbodUI.Drawer
function Drawer:render()
  if not self:is_open() then
    return self
  end
  -- is_open() guarantees a live window, hence a buffer; narrow bufnr to non-nil.
  local bufnr = assert(self.bufnr)
  paint(bufnr, self:build_content(), self.icons)
  return self
end

--- Repaint a SINGLE db node's line in place, setting its icon to `frame` -- the
--- cheap path the loading spinner drives at 80ms instead of a full `render()`.
--- Scans the live `self.content` for the `type == 'db'` node with `key_name`
--- (rescanning each tick rather than caching a line index, so a mid-load toggle
--- can never repaint the wrong line) and rewrites only that line. No-ops when the
--- drawer is closed or the node has been collapsed away.
---
--- The frame is set as the node's trailing `loading_frame` (rendered by
--- `line_for`) rather than swapped into its icon: the db's fold icon + name stay
--- fixed while only the appended spinner animates, so the node doesn't jitter as
--- frames cycle. The next full `render()` rebuilds without `loading_frame` (the
--- `loading` marker having cleared), dropping the trailer.
---@param key_name string
---@param frame string
---@return nil
function Drawer:repaint_db_node(key_name, frame)
  if not self:is_open() then
    return
  end
  local bufnr = assert(self.bufnr)
  for idx, node in ipairs(self.content) do
    if node.type == 'db' and node.key_name == key_name then
      node.loading_frame = frame
      local bo = vim.bo[bufnr]
      bo.modifiable = true
      pcall(vim.api.nvim_buf_set_lines, bufnr, idx - 1, idx, false, { line_for(node) })
      bo.modifiable = false
      return
    end
  end
end

---@return nil
function Drawer:render_help()
  if self.config.show_help then
    self:add({ label = '" Press ? for help', icon = '', level = 0, type = 'help', action = 'noaction' })
    self:add({ label = '', icon = '', level = 0, type = 'help', action = 'noaction' })
  end
  if self.show_help then
    for _, line in ipairs(HELP_LINES) do
      self:add({ label = line, icon = '', level = 0, type = 'help', action = 'noaction' })
    end
    self:add({ label = '', icon = '', level = 0, type = 'help', action = 'noaction' })
  end
end

---@return DadbodUI.Drawer
function Drawer:toggle_help()
  self.show_help = not self.show_help
  return self:render()
end

---@return DadbodUI.Drawer
function Drawer:toggle_details()
  self.show_details = not self.show_details
  return self:render()
end

--- Render the connection list. Ungrouped connections render in place; a group
--- gets a single header at the position of its first member, with *all* members
--- gathered under it -- even when they are not contiguous in dbs_list (an
--- interactive `G` leaves a connection in its original file position, so group
--- members can be interleaved with other entries).
---@return nil
function Drawer:render_dbs()
  local dbs = self.instance.dbs_list
  local seen_groups = {}
  for _, record in ipairs(dbs) do
    local group = record.group or ''
    if group == '' then
      self:render_db(record, 0)
    elseif not seen_groups[group] then
      seen_groups[group] = true
      local gs = self:group_state(group)
      local label = self.show_details and (group .. ' (Group)') or group
      self:add({
        label = label,
        icon = self:toggle_icon('group', gs.expanded),
        level = 0,
        type = 'group',
        action = 'toggle',
        group = group,
        expanded = gs.expanded,
        toggle_state = gs,
      })
      if gs.expanded then
        vim.iter(dbs)
          :filter(function(member)
            return (member.group or '') == group
          end)
          :each(function(member)
            self:render_db(member, 1)
          end)
      end
    end
  end
end

--- Render the top-level `Query results` section listing the executed `.dbout`
--- files (the instance's dbout_list). A toggle header whose `show_dbout_list`
--- state expands to the result files, sorted per `dbout_list_sort`, each opening
--- as a preview. Port of the dbout_list block of `s:drawer.render`.
---@return nil
function Drawer:render_dbout_list()
  if next(self.instance.dbout_list) == nil then
    return
  end
  local files = vim.tbl_keys(self.instance.dbout_list)
  self:add({ label = '', icon = '', level = 0, type = 'help', action = 'noaction' })
  self:add({
    label = string.format('Query results (%d)', #files),
    icon = self:toggle_icon('saved_queries', self.show_dbout_list),
    level = 0,
    type = 'dbout_list',
    action = 'call_method',
    expanded = self.show_dbout_list,
  })
  if not self.show_dbout_list then
    return
  end
  local dbout = require('dadbod-ui.dbout')
  table.sort(files, dbout.sort_dbout)
  for _, file in ipairs(files) do
    local content = self.instance.dbout_list[file]
    local label = vim.fs.basename(file)
    if content ~= nil and content ~= '' then
      label = label .. string.format(' (%s)', content)
    end
    self:add({
      label = label,
      icon = self.icons.tables,
      level = 1,
      type = 'dbout',
      action = 'open',
      file_path = file,
    })
  end
end

---@param record DadbodUI.ConnectionRecord
---@param level integer
function Drawer:render_db(record, level)
  local entry = self.instance.dbs[record.key_name]
  local label = record.name
  if entry.conn_error and entry.conn_error ~= '' then
    label = label .. ' ' .. self.icons.connection_error
  elseif is_connected(entry) then
    label = label .. ' ' .. self.icons.connection_ok
  end
  if self.show_details then
    local parts = { entry.scheme, entry.source }
    if entry.group ~= '' then
      table.insert(parts, string.format('%s %s', self.icons.group, entry.group))
    end
    -- The connect timing lives here (the H-toggle details), not in a popup.
    if entry.connect_ms then
      table.insert(parts, string.format('%dms', entry.connect_ms))
    end
    label = label .. ' (' .. table.concat(parts, ' - ') .. ')'
  end
  -- While connecting/introspecting the db node keeps its own fold icon and name
  -- fixed; the loading state shows as a spinner APPENDED after the label (a
  -- static first frame here, animated in place by `repaint_db_node` over the
  -- async window). The transient `loading` marker is cleared by the introspect
  -- controller on data-land/error, dropping the trailer on the next render.
  self:add({
    label = label,
    icon = self:toggle_icon('db', entry.expanded),
    loading_frame = entry.loading and spinners.dots[1] or nil,
    level = level,
    type = 'db',
    action = 'toggle',
    key_name = record.key_name,
    expanded = entry.expanded,
    -- A db's entry IS its `{ expanded }` table; on_expand runs the lazy
    -- introspection only on the opening flip, never on collapse.
    toggle_state = entry,
    on_expand = function()
      self:introspect():expand_db(entry)
    end,
  })
  if entry.expanded then
    self:render_db_sections(entry, level + 1)
  end
end

---@param entry DadbodUI.ConnectionEntry
---@param level integer
function Drawer:render_db_sections(entry, level)
  for _, section in ipairs(self.config.drawer_sections) do
    if section == 'new_query' then
      self:add({
        label = 'New query',
        icon = self.icons.new_query,
        level = level,
        type = 'query',
        action = 'open',
        key_name = entry.key_name,
      })
    elseif section == 'buffers' and #entry.buffers.list > 0 then
      self:render_buffers_section(entry, level)
    elseif section == 'saved_queries' then
      self:render_saved_queries_section(entry, level)
    elseif section == 'schemas' then
      self:render_schemas_section(entry, level)
    end
  end
end

--- The drawer label for a buffer file: its basename, with the connection's
--- `<slug>-` prefix (and the legacy `db_ui.` wrapper) stripped for tmp buffers.
--- Port of `s:drawer.get_buffer_name`.
---@param entry DadbodUI.ConnectionEntry
---@param buffer string
---@return string
function Drawer:get_buffer_name(entry, buffer)
  local name = vim.fs.basename(buffer)
  if not self.instance:is_tmp_location_buffer(entry, buffer) then
    return name
  end
  if vim.fn.fnamemodify(name, ':r') == 'db_ui' then
    name = vim.fn.fnamemodify(name, ':e')
  end
  return (name:gsub('^' .. vim.pesc(utils.slug(entry.name)) .. '%-', ''))
end

--- Render the Buffers section: a toggle header with the open-buffer count, and
--- on expand each buffer as an `open` node (tmp buffers flagged with ` *`). Port
--- of `s:drawer._render_buffers_section`.
---@param entry DadbodUI.ConnectionEntry
---@param level integer
---@return nil
function Drawer:render_buffers_section(entry, level)
  self:add({
    label = string.format('Buffers (%d)', #entry.buffers.list),
    icon = self:toggle_icon('buffers', entry.buffers.expanded),
    level = level,
    type = 'buffers',
    action = 'toggle',
    key_name = entry.key_name,
    expanded = entry.buffers.expanded,
    toggle_state = entry.buffers,
  })
  if not entry.buffers.expanded then
    return
  end
  for _, buffer in ipairs(entry.buffers.list) do
    local label = self:get_buffer_name(entry, buffer)
    if self.instance:is_tmp_location_buffer(entry, buffer) then
      label = label .. ' *'
    end
    self:add({
      label = label,
      icon = self.icons.buffers,
      level = level + 1,
      type = 'buffer',
      action = 'open',
      key_name = entry.key_name,
      file_path = buffer,
    })
  end
end

--- Render the Saved queries section: a toggle header with the on-disk count, and
--- on expand each saved query as an `open` node carrying its file path. Port of
--- `s:drawer._render_saved_queries_section`.
---@param entry DadbodUI.ConnectionEntry
---@param level integer
---@return nil
function Drawer:render_saved_queries_section(entry, level)
  self:add({
    label = string.format('Saved queries (%d)', #entry.saved_queries.list),
    icon = self:toggle_icon('saved_queries', entry.saved_queries.expanded),
    level = level,
    type = 'saved_queries',
    action = 'toggle',
    key_name = entry.key_name,
    expanded = entry.saved_queries.expanded,
    toggle_state = entry.saved_queries,
  })
  if not entry.saved_queries.expanded then
    return
  end
  for _, saved in ipairs(entry.saved_queries.list) do
    self:add({
      label = vim.fs.basename(saved),
      icon = self.icons.saved_query,
      level = level + 1,
      type = 'saved_query',
      action = 'open',
      key_name = entry.key_name,
      file_path = saved,
      saved = true,
    })
  end
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

--- Render the Schemas (schema-supporting adapters) or Tables (everything else)
--- section. Mirrors the original `_render_schemas_section`: schema-supporting
--- connections nest tables under a per-schema node; the rest list tables
--- directly under the connection.
---@param entry DadbodUI.ConnectionEntry
---@param level integer
function Drawer:render_schemas_section(entry, level)
  if entry.schema_support then
    self:add({
      label = string.format('Schemas (%d)', #entry.schemas.list),
      icon = self:toggle_icon('schemas', entry.schemas.expanded),
      level = level,
      type = 'schemas',
      action = 'toggle',
      key_name = entry.key_name,
      expanded = entry.schemas.expanded,
      toggle_state = entry.schemas,
    })
    if not entry.schemas.expanded then
      return
    end
    for _, schema in ipairs(entry.schemas.list) do
      local schema_item = entry.schemas.items[schema]
      local tables = schema_item.tables
      self:add({
        label = string.format('%s (%d)', schema, #tables.list),
        icon = self:toggle_icon('schema', schema_item.expanded),
        level = level + 1,
        type = 'schema',
        action = 'toggle',
        key_name = entry.key_name,
        expanded = schema_item.expanded,
        toggle_state = schema_item,
      })
      if schema_item.expanded then
        self:render_tables(tables, entry, level + 2, schema)
      end
    end
  else
    self:add({
      label = string.format('Tables (%d)', #entry.tables.list),
      icon = self:toggle_icon('tables', entry.tables.expanded),
      level = level,
      type = 'tables',
      action = 'toggle',
      key_name = entry.key_name,
      expanded = entry.tables.expanded,
      toggle_state = entry.tables,
    })
    self:render_tables(entry.tables, entry, level + 1, '')
  end
end

--- Render the tables of a tables node, each a toggle node that expands to show
--- the adapter's table helpers (helper open actions are wired in a later
--- milestone). Honors a configured `table_name_sorter`.
---@param tables DadbodUI.TablesNode
---@param entry DadbodUI.ConnectionEntry
---@param level integer
---@param schema string
function Drawer:render_tables(tables, entry, level, schema)
  if not tables.expanded then
    return
  end
  local list = tables.list
  if self.config.table_name_sorter then
    list = self.config.table_name_sorter(list)
  end
  for _, table_name in ipairs(list) do
    local table_item = tables.items[table_name]
    self:add({
      label = table_name,
      icon = self:toggle_icon('table', table_item.expanded),
      level = level,
      type = 'table',
      action = 'toggle',
      key_name = entry.key_name,
      expanded = table_item.expanded,
      toggle_state = table_item,
      table = table_name,
      schema = schema,
    })
    if table_item.expanded then
      local ordered = require('dadbod-ui.table_helpers').ordered_names(entry.table_helpers)
      for _, helper_name in ipairs(ordered) do
        self:add({
          label = helper_name,
          icon = self.icons.tables,
          level = level + 1,
          type = 'table_helper',
          action = 'open',
          key_name = entry.key_name,
          table = table_name,
          schema = schema,
          content = entry.table_helpers[helper_name],
        })
      end
    end
  end
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
--   * DRAWER owns transient VIEW state -- `show_help`, `show_details`,
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
-- `show_dbout_list` is the lone exception: like the `show_help`/`show_details`
-- booleans it is flipped by name, here on the `call_method` path. It is left
-- there deliberately to keep the action branches (`call_method`/`open`)
-- untouched -- those are actions, not expand-state flips.

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

---@return nil
function Drawer:setup_mappings()
  ---@param lhs string
  ---@param fn fun()
  local function map(lhs, fn)
    vim.keymap.set('n', lhs, fn, { buffer = self.bufnr, nowait = true, silent = true })
  end
  -- help toggle is always available, matching the original
  map('?', function()
    self:toggle_help()
  end)
  if self.config.disable_mappings or self.config.disable_mappings_dbui then
    return
  end
  map('o', function()
    self:toggle_line()
  end)
  map('<CR>', function()
    self:toggle_line()
  end)
  map('S', function()
    local pos = utils.opposite_position(self.config.win_position)
    self:toggle_line('vertical ' .. pos .. ' split')
  end)
  map('q', function()
    self:quit()
  end)
  map('A', function()
    self:connections():add_connection()
  end)
  map('d', function()
    self:delete_line()
  end)
  map('r', function()
    self:rename_line()
  end)
  map('R', function()
    self:redraw()
  end)
  map('D', function()
    self:duplicate_line()
  end)
  map('G', function()
    self:set_group_line()
  end)
  map('H', function()
    self:toggle_details()
  end)
  map('<C-k>', function()
    self:goto_sibling('first')
  end)
  map('<C-j>', function()
    self:goto_sibling('last')
  end)
  map('K', function()
    self:goto_sibling('prev')
  end)
  map('J', function()
    self:goto_sibling('next')
  end)
  map('<C-p>', function()
    self:goto_node('parent')
  end)
  map('<C-n>', function()
    self:goto_node('child')
  end)
end

-- Exposed for the line-render spec (asserts line_for matches a full paint).
M._line_for = line_for

M.Drawer = Drawer
return M
