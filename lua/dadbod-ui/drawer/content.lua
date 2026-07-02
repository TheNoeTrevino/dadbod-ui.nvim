-- The pure tree builders (instance -> Node[])
--
-- A method mixin merged into `DadbodUI.Drawer` by `drawer/init.lua`: every
-- `render_*` builder plus `build_content` itself. Pure with respect to the
-- window -- these methods append nodes to `self.content` and never touch a
-- buffer (that is `drawer/paint.lua`), which is what keeps `build_content`
-- unit-testable without an open drawer.

local spinners = require('dadbod-ui.spinners')
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
    self:add({
      label = 'Add connection',
      icon = self.icons.add_connection,
      level = 0,
      type = 'add_connection',
      action = 'call_method',
    })
  end
  self:render_dbout_list()
  return self.content
end

---@return nil
function Drawer:render_help()
  if self.config.show_help then
    self:add({ label = '" Press ? for help', icon = '', level = 0, type = 'help', action = 'noaction' })
    self:add({ label = '', icon = '', level = 0, type = 'help', action = 'noaction' })
  end
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
        vim
          .iter(dbs)
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
    elseif section == 'procedures' then
      self:render_routines_section(entry, level)
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

--- The total number of stored procedures/functions introspected for `entry`
--- (summed across schema buckets for a schema adapter, or the flat list for a
--- non-schema adapter). Drives the Procedures header count and the non-empty gate.
---@param entry DadbodUI.ConnectionEntry
---@return integer
function Drawer:routine_count(entry)
  if entry.schema_support then
    return vim.iter(entry.routines.list):fold(0, function(acc, schema)
      local item = entry.routines.items[schema]
      return acc + (item and #item.list or 0)
    end)
  end
  return #entry.routines.flat
end

--- Add one procedure/function leaf node. Its `content` (the adapter's pre-built
--- DDL/source query) rides along so the `open` action reuses the table-helper
--- open path verbatim -- opening it fills a query buffer with the definition SQL,
--- which the user runs to view the source. A `[P]`/`[F]` suffix distinguishes a
--- procedure from a function without depending on an extra icon.
---@param entry DadbodUI.ConnectionEntry
---@param routine DadbodUI.RoutineItem
---@param level integer
---@param schema string
---@return nil
function Drawer:add_routine(entry, routine, level, schema)
  self:add({
    label = string.format('%s [%s]', routine.name, routine.kind == 'procedure' and 'P' or 'F'),
    icon = self.icons.procedures,
    level = level,
    type = 'routine',
    action = 'open',
    key_name = entry.key_name,
    table = routine.name,
    schema = schema,
    content = routine.content,
  })
end

--- Render the Procedures section: stored procedures + functions. Only rendered
--- when the adapter supports routines AND at least one exists (no empty node --
--- mirrors how Buffers only shows when non-empty). Schema-supporting adapters nest
--- routines under a per-schema node (like Schemas -> tables); flat adapters list
--- them directly. Deliberate divergence from upstream vim-dadbod-ui, which lists
--- no procedures/functions at all -- the first DBeaver-style object introspection.
---@param entry DadbodUI.ConnectionEntry
---@param level integer
---@return nil
function Drawer:render_routines_section(entry, level)
  if not entry.routine_support then
    return
  end
  local total = self:routine_count(entry)
  if total == 0 then
    return
  end
  local routines = entry.routines
  self:add({
    label = string.format('Procedures (%d)', total),
    icon = self:toggle_icon('procedures', routines.expanded),
    level = level,
    type = 'routines',
    action = 'toggle',
    key_name = entry.key_name,
    expanded = routines.expanded,
    toggle_state = routines,
  })
  if not routines.expanded then
    return
  end
  if entry.schema_support then
    for _, schema in ipairs(routines.list) do
      local schema_item = routines.items[schema]
      self:add({
        label = string.format('%s (%d)', schema, #schema_item.list),
        icon = self:toggle_icon('routine_schema', schema_item.expanded),
        level = level + 1,
        type = 'routine_schema',
        action = 'toggle',
        key_name = entry.key_name,
        expanded = schema_item.expanded,
        toggle_state = schema_item,
      })
      if schema_item.expanded then
        for _, routine in ipairs(schema_item.list) do
          self:add_routine(entry, routine, level + 2, schema)
        end
      end
    end
  else
    for _, routine in ipairs(routines.flat) do
      self:add_routine(entry, routine, level + 1, '')
    end
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
      local ordered =
        require('dadbod-ui.table_helpers').ordered_names(entry.table_helpers, self.config.table_helpers_order)
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

return Drawer
