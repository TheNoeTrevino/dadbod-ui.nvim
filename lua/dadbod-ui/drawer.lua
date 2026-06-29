---@mod dadbod-ui.drawer  The tree UI (window + content render + interaction)
---
--- Mirrors the original: a scratch buffer whose lines are built from a
--- `content[]` array where line N maps to a node. The cursor line indexes
--- `content` to find the node and its action. Highlighting/ftplugin and the
--- richer sections (tables, schemas, buffers) land in later slices.

local icons_mod = require('dadbod-ui.icons')
local connections = require('dadbod-ui.connections')
local bridge = require('dadbod-ui.bridge')
local schemas = require('dadbod-ui.schemas')
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
---@field groups table<string, { expanded: boolean }>
---@field show_help boolean
---@field show_details boolean
---@field input DadbodUI.UiInput  prompt backend (injectable for specs)
---@field confirm DadbodUI.Confirm  yes/no backend (injectable for specs)
---@field connector fun(url: string): string  connect backend (injectable for specs)
---@field show_dbout_list boolean  whether the Query results section is expanded
---@field _query? DadbodUI.Query  lazily-built query controller
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

--- Rebuild `content` from the instance and write the buffer lines.
---@return DadbodUI.Drawer
function Drawer:render()
  if not self:is_open() then
    return self
  end
  self.content = {}
  self:render_help()
  self:render_dbs()
  if #self.instance.dbs_list == 0 then
    self:add({ label = '" No connections', icon = '', level = 0, type = 'help', action = 'noaction' })
    self:add({ label = 'Add connection', icon = self.icons.add_connection, level = 0, type = 'add_connection', action = 'call_method' })
  end
  self:render_dbout_list()

  local lines = vim.iter(self.content)
    :map(function(node)
      local indent = string.rep(' ', INDENT * node.level)
      local sep = node.icon ~= '' and ' ' or ''
      return indent .. node.icon .. sep .. node.label
    end)
    :totable()

  local bo = vim.bo[self.bufnr]
  bo.modifiable = true
  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
  bo.modifiable = false
  return self
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
    local label = vim.fn.fnamemodify(file, ':t')
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
    if entry.group ~= '' then
      label = label .. string.format(' (%s - %s - %s %s)', entry.scheme, entry.source, self.icons.group, entry.group)
    else
      label = label .. string.format(' (%s - %s)', entry.scheme, entry.source)
    end
  end
  self:add({
    label = label,
    icon = self:toggle_icon('db', entry.expanded),
    level = level,
    type = 'db',
    action = 'toggle',
    key_name = record.key_name,
    expanded = entry.expanded,
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
  local name = vim.fn.fnamemodify(buffer, ':t')
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
      label = vim.fn.fnamemodify(saved, ':t'),
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

--- Refresh `entry.saved_queries.list` from the files on disk under its save_path.
--- Port of `s:drawer.load_saved_queries`.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Drawer:load_saved_queries(entry)
  if entry.save_path ~= '' then
    entry.saved_queries.list = vim.fn.glob(entry.save_path .. '/*', true, true)
  end
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
      for helper_name, helper in pairs(entry.table_helpers) do
        self:add({
          label = helper_name,
          icon = self.icons.tables,
          level = level + 1,
          type = 'table_helper',
          action = 'open',
          key_name = entry.key_name,
          table = table_name,
          schema = schema,
          content = helper,
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
      self:add_connection()
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
  if item.type == 'group' then
    self:group_state(item.group).expanded = not self:group_state(item.group).expanded
    return self:render()
  end
  if item.type == 'db' then
    local entry = self.instance.dbs[item.key_name]
    entry.expanded = not entry.expanded
    -- Lazy-load: only introspect when expanding (kicks off async, renders again
    -- when the schema/table data arrives), never on collapse.
    if entry.expanded then
      self:expand_db(entry)
    end
    return self:render()
  end
  -- Schemas / Tables / schema / table nodes carry a direct reference to the
  -- state they flip, so toggling is a plain re-render (no re-introspection).
  if item.toggle_state ~= nil then
    item.toggle_state.expanded = not item.toggle_state.expanded
    return self:render()
  end
end

-- Schema / table introspection -----------------------------------------------
--
-- Expanding a connection connects (sync, as dadbod does) then introspects. The
-- introspection itself is non-blocking: schema-supporting adapters fan out the
-- schema-list and table-list queries concurrently via `bridge.run_many`; the
-- tables-only path uses dadbod's `tables` adapter call. Each path re-renders the
-- drawer once its data lands, so a large database never freezes the UI.

--- Connect a connection if not already connected. Errors are captured on the
--- entry (surfaced as the error icon) and notified, mirroring the original.
---@param entry DadbodUI.ConnectionEntry
---@return DadbodUI.ConnectionEntry
function Drawer:connect(entry)
  if is_connected(entry) then
    return entry
  end
  local notify = require('dadbod-ui.notifications')
  notify.info(string.format('Connecting to db %s...', entry.name))
  local started = vim.uv.hrtime()
  local ok, conn = pcall(self.connector, entry.url)
  if ok then
    entry.conn = conn
    entry.conn_error = ''
    local elapsed_ms = math.floor((vim.uv.hrtime() - started) / 1e6 + 0.5)
    notify.info(string.format('Connected to db %s. Took %dms to connect.', entry.name, elapsed_ms))
  else
    entry.conn = ''
    entry.conn_error = tostring(conn)
    notify.error(string.format('Error connecting to db %s: %s', entry.name, tostring(conn)))
  end
  entry.conn_tried = true
  return entry
end

--- Introspect a connected entry: schema-supporting adapters fan out their
--- schema/table queries, the rest list tables directly. Port of
--- `drawer.populate`.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Drawer:populate(entry)
  if entry.schema_support then
    self:populate_schemas(entry)
  else
    self:populate_tables(entry)
  end
end

--- Connect then introspect a connection on expand.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Drawer:expand_db(entry)
  self:load_saved_queries(entry)
  self:connect(entry)
  if not is_connected(entry) then
    return
  end
  if entry.schema_support then
    self:populate_schemas(entry)
  else
    -- Defer so the initial expand render paints before the (blocking) adapter
    -- call; keeps the keypress responsive even for the tables-only path.
    vim.schedule(function()
      self:populate_tables(entry)
    end)
  end
end

--- Whether `schema_name` matches any `hide_schemas` pattern (Vim regexes, as in
--- the original).
---@param schema_name string
---@return boolean
function Drawer:_is_schema_ignored(schema_name)
  for _, pattern in ipairs(self.config.hide_schemas) do
    if vim.fn.match(schema_name, pattern) > -1 then
      return true
    end
  end
  return false
end

--- Ensure every table in `tables.list` has an expand-state item, preserving the
--- existing ones (so a refresh keeps tables expanded). Port of
--- `populate_table_items`.
---@param tables DadbodUI.TablesNode
---@return nil
function Drawer:populate_table_items(tables)
  for _, table_name in ipairs(tables.list) do
    if tables.items[table_name] == nil then
      tables.items[table_name] = { expanded = false }
    end
  end
end

--- Introspect schemas + tables concurrently and render. Port of
--- `populate_schemas`, with the two queries fanned out via `run_many`.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Drawer:populate_schemas(entry)
  if not is_connected(entry) then
    return
  end
  local scheme_info = schemas.get(entry.scheme, self.config)
  local specs = {
    schemas.command_spec(entry.conn, scheme_info, scheme_info.schemes_query),
    schemas.command_spec(entry.conn, scheme_info, scheme_info.schemes_tables_query),
  }
  bridge.run_many(specs, function(results)
    local schema_list = scheme_info.parse_results(schemas.result_lines(results[1]), 1)
    local table_rows = scheme_info.parse_results(schemas.result_lines(results[2]), 2)
    self:apply_schemas(entry, schema_list, table_rows)
    self:render()
  end)
end

--- Fold parsed schema names and (schema, table) rows into the entry, honoring
--- `hide_schemas`. Port of the body of `populate_schemas`: tables are grouped
--- per schema and also collected into the flat `entry.tables.list`.
---@param entry DadbodUI.ConnectionEntry
---@param schema_list string[]
---@param table_rows string[][]
---@return nil
function Drawer:apply_schemas(entry, schema_list, table_rows)
  local visible_schemas = vim.tbl_filter(function(schema)
    return not self:_is_schema_ignored(schema)
  end, schema_list)

  local tables_by_schema = {}
  entry.tables.list = {}
  for _, row in ipairs(table_rows) do
    local schema_name, table_name = row[1], row[2]
    if not self:_is_schema_ignored(schema_name) then
      tables_by_schema[schema_name] = tables_by_schema[schema_name] or {}
      table.insert(tables_by_schema[schema_name], table_name)
      table.insert(entry.tables.list, table_name)
    end
  end

  entry.schemas.list = visible_schemas
  for _, schema in ipairs(visible_schemas) do
    if entry.schemas.items[schema] == nil then
      entry.schemas.items[schema] = {
        expanded = false,
        tables = { expanded = true, list = {}, items = {} },
      }
    end
    local schema_tables = tables_by_schema[schema] or {}
    table.sort(schema_tables)
    entry.schemas.items[schema].tables.list = schema_tables
    self:populate_table_items(entry.schemas.items[schema].tables)
  end
end

--- Introspect tables for a non-schema adapter (e.g. sqlite) via dadbod's
--- `tables` adapter call and render. Port of `populate_tables`, including the
--- sqlite whitespace fix and the mysql warning filter.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Drawer:populate_tables(entry)
  entry.tables.list = {}
  if not is_connected(entry) then
    return
  end
  local raw = bridge.adapter_call(entry.conn, 'tables', { entry.conn }, {})
  entry.tables.list = schemas.normalize_table_list(entry.scheme, raw)
  self:populate_table_items(entry.tables)
  self:render()
end

-- Interactive connection management ------------------------------------------
--
-- These wire the drawer keys (A/d/r/R) to the pure CRUD transforms in
-- connections.lua. Prompts go through `self.input` (vim.ui.input by default),
-- so each flow is callback-based; all user-facing messages route through the
-- notifications layer. On success we write connections.json, re-discover, and
-- re-render.

--- Resolve and validate a url the user typed. Returns `(resolved, nil)` or
--- `(nil, err)` when dadbod rejects it.
---@param url string
---@return string|nil, string|nil
local function validate_url(url)
  local ok, result = pcall(function()
    local resolved = bridge.resolve(url)
    bridge.parse_url(resolved)
    return resolved
  end)
  if not ok then
    return nil, tostring(result)
  end
  return result, nil
end

--- Read the connections.json store, refusing to proceed when it is present but
--- corrupt -- so a CRUD action can't silently overwrite a file we failed to
--- parse. Returns the list, or nil when the store is unreadable.
---@return DadbodUI.FileConnection[]|nil
function Drawer:read_store()
  local corrupt = false
  local list = connections.read_file(self.instance.connections_path, function()
    corrupt = true
  end)
  if corrupt then
    require('dadbod-ui.notifications').error(
      'Could not read connections file; refusing to overwrite it. Fix or remove: ' .. (self.instance.connections_path or '')
    )
    return nil
  end
  return list
end

--- Persist `connections.json`, re-discover, and re-render.
---@param list DadbodUI.FileConnection[]
---@return nil
function Drawer:commit_connections(list)
  local path = self.instance.connections_path
  if path == nil then
    return
  end
  connections.write_file(path, list)
  self.instance:repopulate()
  self:render()
end

--- Add a new file-source connection (also `:DBUIAddConnection`). Prompts for a
--- url then a name; rejects an invalid url, a blank name, or a duplicate name.
---@return nil
function Drawer:add_connection()
  local notify = require('dadbod-ui.notifications')
  if self.instance.connections_path == nil then
    return notify.error('Please set up valid save location via g:db_ui_save_location')
  end
  self.input({ prompt = 'Enter connection url: ' }, function(url)
    if url == nil then
      return
    end
    local resolved, err = validate_url(url)
    if resolved == nil then
      return notify.error(err or 'Invalid connection url.')
    end
    self.input({ prompt = 'Enter name: ', default = resolved:match('[^/]*$') }, function(name)
      if name == nil then
        return
      end
      name = vim.trim(name)
      if name == '' then
        return notify.error('Please enter valid name.')
      end
      local store = self:read_store()
      if store == nil then
        return
      end
      local list, add_err = connections.add_connection(store, name, resolved)
      if list == nil then
        return notify.error(add_err or 'Could not add connection.')
      end
      self:commit_connections(list)
      notify.info('Saved connection.')
    end)
  end)
end

--- Rename/edit a connection. Only file-source connections are editable; others
--- are refused with a notification. Prompts for a new url then a new name.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Drawer:rename_connection(entry)
  local notify = require('dadbod-ui.notifications')
  if entry.source ~= 'file' then
    return notify.error('Cannot edit connections added via variables.')
  end
  self.input({ prompt = string.format('Edit connection url for "%s": ', entry.name), default = entry.url }, function(url)
    if url == nil then
      return
    end
    local resolved, err = validate_url(url)
    if resolved == nil then
      return notify.error(err or 'Invalid connection url.')
    end
    self.input({ prompt = 'Edit connection name: ', default = entry.name }, function(name)
      if name == nil then
        return
      end
      name = vim.trim(name)
      if name == '' then
        return notify.error('Please enter valid name.')
      end
      local store = self:read_store()
      if store == nil then
        return
      end
      local list, rename_err = connections.rename_connection(store, entry.name, entry.url, name, resolved)
      if list == nil then
        return notify.error(rename_err or 'Could not rename connection.')
      end
      self:commit_connections(list)
    end)
  end)
end

--- Duplicate a connection into the file store (`D`). Prompts for a name
--- (prefilled from the source), a url (prefilled from the source), then a group
--- (prefilled from the source). Because the same name is allowed in different
--- groups, the natural clone is "keep the name, change the group" -- e.g.
--- `geekom/postgres` -> `pi/postgres`. Works on any source: the result is always
--- a file connection, so a `g:dbs`/env entry can be cloned into an editable one.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Drawer:duplicate_connection(entry)
  local notify = require('dadbod-ui.notifications')
  if self.instance.connections_path == nil then
    return notify.error('Please set up valid save location via g:db_ui_save_location')
  end
  self.input({ prompt = 'Enter name for the duplicate: ', default = entry.name }, function(name)
    if name == nil then
      return
    end
    name = vim.trim(name)
    if name == '' then
      return notify.error('Please enter valid name.')
    end
    self.input({ prompt = 'Enter connection url: ', default = entry.url }, function(url)
      if url == nil then
        return
      end
      local resolved, err = validate_url(url)
      if resolved == nil then
        return notify.error(err or 'Invalid connection url.')
      end
      self.input({ prompt = 'Enter group (optional): ', default = entry.group }, function(group)
        if group == nil then
          return
        end
        group = vim.trim(group)
        local store = self:read_store()
        if store == nil then
          return
        end
        local list, dup_err = connections.duplicate_connection(store, name, resolved, group)
        if list == nil then
          return notify.error(dup_err or 'Could not duplicate connection.')
        end
        self:commit_connections(list)
        notify.info('Duplicated connection.')
      end)
    end)
  end)
end

--- Assign a connection to a group (or clear it). A group is just a shared name:
--- entering an existing group joins it, a new name creates it, and an empty
--- entry ungroups. Only file-source connections are editable.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Drawer:set_group(entry)
  local notify = require('dadbod-ui.notifications')
  if entry.source ~= 'file' then
    return notify.error('Cannot edit connections added via variables.')
  end
  self.input({ prompt = 'Enter group name: ', default = entry.group }, function(group)
    if group == nil then
      return
    end
    group = vim.trim(group)
    local store = self:read_store()
    if store == nil then
      return
    end
    local list, err = connections.set_group(store, entry.name, entry.url, group)
    if list == nil then
      return notify.error(err or 'Could not set group.')
    end
    self:commit_connections(list)
  end)
end

--- Group the connection under the cursor (`G`).
---@return nil
function Drawer:set_group_line()
  local item = self:get_current_item()
  if item == nil then
    return
  end
  if item.type == 'db' then
    return self:set_group(self.instance.dbs[item.key_name])
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
    return self:duplicate_connection(self.instance.dbs[item.key_name])
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
    return self:delete_connection(entry)
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
  local bufnr = vim.fn.bufnr(file)
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

--- Confirm, then remove a file-source connection.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Drawer:delete_connection(entry)
  if not self.confirm(string.format('Are you sure you want to delete connection %s?', entry.name)) then
    return
  end
  local store = self:read_store()
  if store == nil then
    return
  end
  local list = connections.delete_connection(store, entry.name, entry.url)
  self:commit_connections(list)
end

--- Rename the node under the cursor (`r`). Connections route to
--- `rename_connection`; open buffers and saved queries route to `rename_buffer`.
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
    return self:rename_connection(self.instance.dbs[item.key_name])
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
  if vim.fn.filereadable(buffer) ~= 1 then
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
      vim.fn.setbufvar(new_bufnr, 'dbui_db_key_name', entry.key_name)
      vim.fn.setbufvar(new_bufnr, 'db', entry.conn)
      vim.fn.setbufvar(new_bufnr, 'dbui_table_name', vim.fn.getbufvar(buffer, 'dbui_table_name'))
      vim.fn.setbufvar(new_bufnr, 'dbui_bind_params', vim.fn.getbufvar(buffer, 'dbui_bind_params'))
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
      self:populate(entry)
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
    self:add_connection()
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

M.Drawer = Drawer
return M
