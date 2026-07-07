-- The pure tree builders (instance -> node tree -> flat Node[])
--
-- A method mixin merged into `DadbodUI.Drawer` by `drawer/init.lua`. Builders
-- return real tree nodes carrying `children` arrays; `build_content` flattens
-- the tree depth-first into `self.content` (line N -> node), assigning each
-- node its `level` (its tree depth), `parent` and `index` as it goes. The flat
-- array is only the paint/line-lookup projection; navigation walks the tree.
-- Pure with respect to the window -- no builder touches a buffer (that is
-- `drawer/paint.lua`), which keeps `build_content` unit-testable without an
-- open drawer.
--
-- Expand/collapse state lives in the drawer's `expand` map (view state), keyed
-- by the stable node ids in `drawer/ids.lua` -- never in the connection
-- entries (domain data). A collapsed node simply builds no `children`, so
-- lazily-introspected data is never demanded early.

local ids = require('dadbod-ui.drawer.ids')
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

---@private
--- A non-actionable chrome line (`"`-comment hint or blank separator). Rendered
--- like any node but skipped by navigation and every verb.
---@param label string
---@return DadbodUI.Node
local function hint(label)
  return { label = label, icon = '', type = 'help', action = 'noaction' }
end

---@class DadbodUI.Drawer
local Drawer = {}

---@param kind string
---@param expanded boolean
---@return string
function Drawer:toggle_icon(kind, expanded)
  return expanded and self.icons.expanded[kind] or self.icons.collapsed[kind]
end

--- Rebuild the drawer tree from the instance and flatten it: `self.roots` holds
--- the tree (navigation walks parents/children), `self.content` the flat
--- line-indexed projection (paint + cursor lookup). Returns the flat list.
---@return DadbodUI.Node[]
function Drawer:build_content()
  local roots = {}
  if self.config.drawer.show_help then
    roots[#roots + 1] = hint('" Press ? for help')
    roots[#roots + 1] = hint('')
  end
  self:build_dbs(roots)
  if #self.instance.dbs_list == 0 then
    roots[#roots + 1] = hint('" No connections')
    roots[#roots + 1] = {
      label = 'Add connection',
      icon = self.icons.add_connection,
      type = 'add_connection',
      action = 'call_method',
    }
  end
  self:build_dbout_section(roots)
  self.roots = roots
  self.content = {}
  self:flatten(roots, 0, nil)
  return self.content
end

---@private
--- Depth-first flatten: assign `level` (tree depth), `parent` and `index`, and
--- append to `self.content` so line N maps to a node.
---@param nodes DadbodUI.Node[]
---@param level integer
---@param parent DadbodUI.Node|nil
---@return nil
function Drawer:flatten(nodes, level, parent)
  for _, node in ipairs(nodes) do
    node.level = level
    node.parent = parent
    self.content[#self.content + 1] = node
    node.index = #self.content
    if node.children ~= nil then
      self:flatten(node.children, level + 1, node)
    end
  end
end

--- Build the connection nodes into `roots`. Ungrouped connections land in
--- place; a group gets a single node at the position of its first member, with
--- *all* members gathered as its children -- even when they are not contiguous
--- in dbs_list (an interactive `G` leaves a connection in its original file
--- position, so group members can be interleaved with other entries).
---@param roots DadbodUI.Node[]
---@return nil
function Drawer:build_dbs(roots)
  local dbs = self.instance.dbs_list
  local seen_groups = {}
  for _, record in ipairs(dbs) do
    local group = record.group or ''
    if group == '' then
      roots[#roots + 1] = self:build_db(record)
    elseif not seen_groups[group] then
      seen_groups[group] = true
      local id = ids.group(group)
      local expanded = self:is_expanded(id, self.config.drawer.expand_groups)
      local node = {
        label = self.show_details and (group .. ' (Group)') or group,
        icon = self:toggle_icon('group', expanded),
        type = 'group',
        action = 'toggle',
        id = id,
        group = group,
        expanded = expanded,
      }
      if expanded then
        node.children = {}
        for _, member in ipairs(dbs) do
          if (member.group or '') == group then
            node.children[#node.children + 1] = self:build_db(member)
          end
        end
      end
      roots[#roots + 1] = node
    end
  end
end

--- Build the top-level `Query results` section listing the executed `.dbout`
--- files (the instance's dbout_list): a toggle node expanding to the result
--- files, sorted per `dbout_list_sort`, each opening as a preview.
---@param roots DadbodUI.Node[]
---@return nil
function Drawer:build_dbout_section(roots)
  if next(self.instance.dbout_list) == nil then
    return
  end
  local files = vim.tbl_keys(self.instance.dbout_list)
  roots[#roots + 1] = hint('')
  local expanded = self:is_expanded(ids.DBOUT)
  local node = {
    label = string.format('Query results (%d)', #files),
    icon = self:toggle_icon('saved_queries', expanded),
    type = 'dbout_list',
    action = 'toggle',
    id = ids.DBOUT,
    expanded = expanded,
  }
  roots[#roots + 1] = node
  if not expanded then
    return
  end
  local dbout = require('dadbod-ui.dbout')
  table.sort(files, dbout.sort_dbout)
  node.children = {}
  for _, file in ipairs(files) do
    local content = self.instance.dbout_list[file]
    local label = vim.fs.basename(file)
    if content ~= nil and content ~= '' then
      label = label .. string.format(' (%s)', content)
    end
    node.children[#node.children + 1] = {
      label = label,
      icon = self.icons.tables,
      type = 'dbout',
      action = 'open',
      file_path = file,
    }
  end
end

---@param record DadbodUI.ConnectionRecord
---@return DadbodUI.Node
function Drawer:build_db(record)
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
  local id = ids.db(record.key_name)
  local expanded = self:is_expanded(id)
  -- While connecting/introspecting the db node keeps its own fold icon and name
  -- fixed; the loading state shows as a spinner APPENDED after the label (a
  -- static first frame here, animated in place by `repaint_db_node` over the
  -- async window). The transient `loading` marker is cleared by the introspect
  -- controller on data-land/error, dropping the trailer on the next render.
  local node = {
    label = label,
    icon = self:toggle_icon('db', expanded),
    loading_frame = entry.loading and spinners.dots[1] or nil,
    type = 'db',
    action = 'toggle',
    id = id,
    key_name = record.key_name,
    expanded = expanded,
    -- on_expand runs the lazy introspection only on the opening flip, never on
    -- collapse.
    on_expand = function()
      self:introspect():expand_db(entry)
    end,
  }
  if expanded then
    node.children = self:build_db_sections(entry)
  end
  return node
end

---@param entry DadbodUI.ConnectionEntry
---@return DadbodUI.Node[]
function Drawer:build_db_sections(entry)
  local children = {}
  for _, section in ipairs(self.config.drawer.sections) do
    if section == 'new_query' then
      children[#children + 1] = {
        label = 'New query',
        icon = self.icons.new_query,
        type = 'query',
        action = 'open',
        key_name = entry.key_name,
      }
    elseif section == 'buffers' and #entry.buffers.list > 0 then
      children[#children + 1] = self:build_buffers_section(entry)
    elseif section == 'saved_queries' then
      children[#children + 1] = self:build_saved_queries_section(entry)
    elseif section == 'schemas' then
      children[#children + 1] = self:build_schemas_section(entry)
    elseif section == 'procedures' then
      local node = self:build_routines_section(entry)
      if node ~= nil then
        children[#children + 1] = node
      end
    end
  end
  return children
end

--- The drawer label for a buffer file: its basename, with the connection's
--- `<slug>-` prefix (and the legacy `db_ui.` wrapper) stripped for tmp buffers.
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
  return (name:gsub('^' .. vim.pesc(utils.slug(entry.save_name)) .. '%-', ''))
end

--- Build the Buffers section: a toggle node with the open-buffer count whose
--- children are the buffers as `open` nodes (tmp buffers flagged with ` *`).
---@param entry DadbodUI.ConnectionEntry
---@return DadbodUI.Node
function Drawer:build_buffers_section(entry)
  local id = ids.section(entry.key_name, 'buffers')
  local expanded = self:is_expanded(id)
  local node = {
    label = string.format('Buffers (%d)', #entry.buffers.list),
    icon = self:toggle_icon('buffers', expanded),
    type = 'buffers',
    action = 'toggle',
    id = id,
    key_name = entry.key_name,
    expanded = expanded,
  }
  if not expanded then
    return node
  end
  node.children = {}
  for _, buffer in ipairs(entry.buffers.list) do
    local label = self:get_buffer_name(entry, buffer)
    if self.instance:is_tmp_location_buffer(entry, buffer) then
      label = label .. ' *'
    end
    node.children[#node.children + 1] = {
      label = label,
      icon = self.icons.buffers,
      type = 'buffer',
      action = 'open',
      key_name = entry.key_name,
      file_path = buffer,
    }
  end
  return node
end

--- Build the Saved queries section: a toggle node with the on-disk count whose
--- children are the saved queries as `open` nodes carrying their file paths.
---@param entry DadbodUI.ConnectionEntry
---@return DadbodUI.Node
function Drawer:build_saved_queries_section(entry)
  local id = ids.section(entry.key_name, 'saved_queries')
  local expanded = self:is_expanded(id)
  local node = {
    label = string.format('Saved queries (%d)', #entry.saved_queries.list),
    icon = self:toggle_icon('saved_queries', expanded),
    type = 'saved_queries',
    action = 'toggle',
    id = id,
    key_name = entry.key_name,
    expanded = expanded,
  }
  if not expanded then
    return node
  end
  node.children = {}
  for _, saved in ipairs(entry.saved_queries.list) do
    node.children[#node.children + 1] = {
      label = vim.fs.basename(saved),
      icon = self.icons.saved_query,
      type = 'saved_query',
      action = 'open',
      key_name = entry.key_name,
      file_path = saved,
      saved = true,
    }
  end
  return node
end

--- Build the Schemas (schema-supporting adapters) or Tables (everything else)
--- section: schema-supporting connections nest tables under per-schema nodes;
--- the rest hang tables directly off the Tables node.
---@param entry DadbodUI.ConnectionEntry
---@return DadbodUI.Node
function Drawer:build_schemas_section(entry)
  if entry.schema_support then
    local id = ids.section(entry.key_name, 'schemas')
    local expanded = self:is_expanded(id)
    local node = {
      label = string.format('Schemas (%d)', #entry.schemas.list),
      icon = self:toggle_icon('schemas', expanded),
      type = 'schemas',
      action = 'toggle',
      id = id,
      key_name = entry.key_name,
      expanded = expanded,
    }
    if not expanded then
      return node
    end
    node.children = {}
    for _, schema in ipairs(entry.schemas.list) do
      local tables = entry.schemas.items[schema].tables
      local schema_id = ids.schema(entry.key_name, schema)
      local schema_expanded = self:is_expanded(schema_id)
      local schema_node = {
        label = string.format('%s (%d)', schema, #tables.list),
        icon = self:toggle_icon('schema', schema_expanded),
        type = 'schema',
        action = 'toggle',
        id = schema_id,
        key_name = entry.key_name,
        expanded = schema_expanded,
      }
      if schema_expanded then
        schema_node.children = self:build_tables(tables.list, entry, schema)
      end
      node.children[#node.children + 1] = schema_node
    end
    return node
  end
  local id = ids.section(entry.key_name, 'tables')
  local expanded = self:is_expanded(id)
  local node = {
    label = string.format('Tables (%d)', #entry.tables.list),
    icon = self:toggle_icon('tables', expanded),
    type = 'tables',
    action = 'toggle',
    id = id,
    key_name = entry.key_name,
    expanded = expanded,
  }
  if expanded then
    node.children = self:build_tables(entry.tables.list, entry, '')
  end
  return node
end

--- The total number of stored procedures/functions introspected for `entry`
--- (summed across schema buckets for a schema adapter, or the flat list for a
--- non-schema adapter). Drives the Procedures node count and the non-empty gate.
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

--- Build one procedure/function leaf node. Its `content` (the adapter's
--- pre-built DDL/source query) rides along so the `open` action reuses the
--- table-helper open path verbatim -- opening it fills a query buffer with the
--- definition SQL, which the user runs to view the source. A `[P]`/`[F]` suffix
--- distinguishes a procedure from a function without depending on an extra icon.
---@param entry DadbodUI.ConnectionEntry
---@param routine DadbodUI.RoutineItem
---@param schema string
---@return DadbodUI.Node
function Drawer:build_routine(entry, routine, schema)
  return {
    label = string.format('%s [%s]', routine.name, routine.kind == 'procedure' and 'P' or 'F'),
    icon = self.icons.procedures,
    type = 'routine',
    action = 'open',
    key_name = entry.key_name,
    table = routine.name,
    schema = schema,
    content = routine.content,
  }
end

--- Build the Procedures section: stored procedures + functions. Returns nil
--- when the adapter lacks routine support OR none exist (no empty node --
--- mirrors how Buffers only shows when non-empty). Schema-supporting adapters
--- nest routines under per-schema nodes (like Schemas -> tables); flat adapters
--- list them directly.
---@param entry DadbodUI.ConnectionEntry
---@return DadbodUI.Node|nil
function Drawer:build_routines_section(entry)
  if not entry.routine_support then
    return nil
  end
  local total = self:routine_count(entry)
  if total == 0 then
    return nil
  end
  local routines = entry.routines
  local id = ids.section(entry.key_name, 'routines')
  local expanded = self:is_expanded(id)
  local node = {
    label = string.format('Procedures (%d)', total),
    icon = self:toggle_icon('procedures', expanded),
    type = 'routines',
    action = 'toggle',
    id = id,
    key_name = entry.key_name,
    expanded = expanded,
  }
  if not expanded then
    return node
  end
  node.children = {}
  if entry.schema_support then
    for _, schema in ipairs(routines.list) do
      local schema_item = routines.items[schema]
      local schema_id = ids.routine_schema(entry.key_name, schema)
      local schema_expanded = self:is_expanded(schema_id)
      local schema_node = {
        label = string.format('%s (%d)', schema, #schema_item.list),
        icon = self:toggle_icon('routine_schema', schema_expanded),
        type = 'routine_schema',
        action = 'toggle',
        id = schema_id,
        key_name = entry.key_name,
        expanded = schema_expanded,
      }
      if schema_expanded then
        schema_node.children = {}
        for _, routine in ipairs(schema_item.list) do
          schema_node.children[#schema_node.children + 1] = self:build_routine(entry, routine, schema)
        end
      end
      node.children[#node.children + 1] = schema_node
    end
  else
    for _, routine in ipairs(routines.flat) do
      node.children[#node.children + 1] = self:build_routine(entry, routine, '')
    end
  end
  return node
end

--- Build the table nodes for a table list, each a toggle node whose children
--- are the adapter's table helpers. Honors a configured `table_name_sorter`.
---@param list string[]
---@param entry DadbodUI.ConnectionEntry
---@param schema string
---@return DadbodUI.Node[]
function Drawer:build_tables(list, entry, schema)
  if self.config.table_name_sorter then
    list = self.config.table_name_sorter(list)
  end
  local nodes = {}
  for _, table_name in ipairs(list) do
    local id = ids.table(entry.key_name, schema, table_name)
    local expanded = self:is_expanded(id)
    local node = {
      label = table_name,
      icon = self:toggle_icon('table', expanded),
      type = 'table',
      action = 'toggle',
      id = id,
      key_name = entry.key_name,
      expanded = expanded,
      table = table_name,
      schema = schema,
    }
    if expanded then
      node.children = {}
      local ordered =
        require('dadbod-ui.table_helpers').ordered_names(entry.table_helpers, self.config.table_helpers_order)
      for _, helper_name in ipairs(ordered) do
        node.children[#node.children + 1] = {
          label = helper_name,
          icon = self.icons.tables,
          type = 'table_helper',
          action = 'open',
          key_name = entry.key_name,
          table = table_name,
          schema = schema,
          content = entry.table_helpers[helper_name],
        }
      end
    end
    nodes[#nodes + 1] = node
  end
  return nodes
end

return Drawer
