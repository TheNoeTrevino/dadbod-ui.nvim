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
local spinner = require('dadbod-ui.spinner')
local spinners = require('dadbod-ui.spinners')
local table_helpers = require('dadbod-ui.table_helpers')

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

--- The spec for `toggle_node` (drawer-internal).
---@class DadbodUI.ToggleNodeSpec
---@field id string  stable expand-map id (drawer/ids.lua)
---@field type string  node type (also the fold-icon kind unless `icon` overrides)
---@field label string
---@field icon? string  fold-icon kind when it differs from `type`
---@field key_name? string
---@field default? boolean  expand state before the user ever touches the node
---@field extra? table<string, any>  additional node fields (group, on_expand, ...)

--- Common toggle-node constructor: computes the expand state from the drawer's
--- map and stamps the fields every toggle node shares. Children stay the
--- caller's job (built only when expanded).
---@param spec DadbodUI.ToggleNodeSpec
---@return DadbodUI.Node node
---@return boolean expanded
function Drawer:toggle_node(spec)
  local expanded = self:is_expanded(spec.id, spec.default)
  local node = {
    label = spec.label,
    icon = self:toggle_icon(spec.icon or spec.type, expanded),
    type = spec.type,
    action = 'toggle',
    id = spec.id,
    key_name = spec.key_name,
    expanded = expanded,
  }
  for key, value in pairs(spec.extra or {}) do
    node[key] = value
  end
  return node, expanded
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
      action = 'activate',
      on_activate = function()
        self:connections():add_connection()
      end,
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
      local node, expanded = self:toggle_node({
        id = ids.group(group),
        type = 'group',
        label = self.show_details and (group .. ' (Group)') or group,
        default = self.config.drawer.expand_groups,
        extra = { group = group },
      })
      if expanded then
        node.children = vim
          .iter(dbs)
          :filter(function(member)
            return (member.group or '') == group
          end)
          :map(function(member)
            return self:build_db(member)
          end)
          :totable()
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
  local node, expanded = self:toggle_node({
    id = ids.DBOUT,
    type = 'dbout_list',
    icon = 'saved_queries',
    label = string.format('Query results (%d)', #files),
  })
  roots[#roots + 1] = node
  if not expanded then
    return
  end
  local dbout = require('dadbod-ui.dbout')
  table.sort(files, dbout.sort_dbout)
  node.children = vim
    .iter(files)
    :map(function(file)
      local content = self.instance.dbout_list[file]
      local label = vim.fs.basename(file)
      if content ~= nil and content ~= '' then
        label = label .. string.format(' (%s)', content)
      end
      return {
        label = label,
        icon = self.icons.tables,
        type = 'dbout',
        action = 'open',
        file_path = file,
      }
    end)
    :totable()
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
  -- While connecting/introspecting the db node keeps its own fold icon and name
  -- fixed; the loading state shows as a spinner APPENDED after the label (a
  -- static first frame here, animated in place by `repaint_db_node` over the
  -- async window). The transient `loading` marker is cleared by the introspect
  -- controller on data-land/error, dropping the trailer on the next render.
  local node, expanded = self:toggle_node({
    id = ids.db(record.key_name),
    type = 'db',
    label = label,
    key_name = record.key_name,
    extra = {
      loading_frame = entry.loading and spinners.dots[1] or nil,
      -- on_expand runs the lazy introspection only on the opening flip;
      -- on_collapse stops a mid-load animation so no timer leaks and no stale
      -- spinner reappears.
      on_expand = function()
        self:introspect():expand_db(entry)
      end,
      on_collapse = function()
        spinner.stop(entry.key_name)
        entry.loading = false
      end,
    },
  })
  if expanded then
    node.children = self:build_db_sections(entry)
  end
  return node
end

--- Build the section nodes under an expanded connection, in configured order.
--- Every `build_*_section` returns `Node|nil` -- nil means the section has
--- nothing to show (empty Buffers, no routines) and is uniformly skipped here.
---@param entry DadbodUI.ConnectionEntry
---@return DadbodUI.Node[]
function Drawer:build_db_sections(entry)
  local children = {}
  for _, section in ipairs(self.config.drawer.sections) do
    local node
    if section == 'new_query' then
      node = {
        label = 'New query',
        icon = self.icons.new_query,
        type = 'query',
        action = 'open',
        key_name = entry.key_name,
      }
    elseif section == 'buffers' then
      node = self:build_buffers_section(entry)
    elseif section == 'saved_queries' then
      node = self:build_saved_queries_section(entry)
    elseif section == 'schemas' then
      node = self:build_schemas_section(entry)
    elseif section == 'procedures' then
      node = self:build_routines_section(entry)
    end
    if node ~= nil then
      children[#children + 1] = node
    end
  end
  return children
end

--- Build the Buffers section: a toggle node with the open-buffer count whose
--- children are the buffers as `open` nodes (tmp buffers flagged with ` *`).
--- Nil when the connection has no open buffers.
---@param entry DadbodUI.ConnectionEntry
---@return DadbodUI.Node|nil
function Drawer:build_buffers_section(entry)
  if #entry.buffers == 0 then
    return nil
  end
  local node, expanded = self:toggle_node({
    id = ids.section(entry.key_name, 'buffers'),
    type = 'buffers',
    label = string.format('Buffers (%d)', #entry.buffers),
    key_name = entry.key_name,
  })
  if not expanded then
    return node
  end
  node.children = vim
    .iter(entry.buffers)
    :map(function(buffer)
      local label = vim.fs.basename(buffer)
      if self.instance:is_tmp_location_buffer(buffer) then
        label = label .. ' *'
      end
      return {
        label = label,
        icon = self.icons.buffers,
        type = 'buffer',
        action = 'open',
        key_name = entry.key_name,
        file_path = buffer,
      }
    end)
    :totable()
  return node
end

--- Build the Saved queries section: a toggle node with the on-disk count whose
--- children are the saved queries as `open` nodes carrying their file paths.
---@param entry DadbodUI.ConnectionEntry
---@return DadbodUI.Node
function Drawer:build_saved_queries_section(entry)
  local node, expanded = self:toggle_node({
    id = ids.section(entry.key_name, 'saved_queries'),
    type = 'saved_queries',
    label = string.format('Saved queries (%d)', #entry.saved_queries),
    key_name = entry.key_name,
  })
  if not expanded then
    return node
  end
  node.children = vim
    .iter(entry.saved_queries)
    :map(function(saved)
      return {
        label = vim.fs.basename(saved),
        icon = self.icons.saved_query,
        type = 'saved_query',
        action = 'open',
        key_name = entry.key_name,
        file_path = saved,
        saved = true,
      }
    end)
    :totable()
  return node
end

--- Build the Schemas (schema-supporting adapters) or Tables (everything else)
--- section: schema-supporting connections nest tables under per-schema nodes;
--- the rest hang tables directly off the Tables node.
---@param entry DadbodUI.ConnectionEntry
---@return DadbodUI.Node
function Drawer:build_schemas_section(entry)
  if not entry.schema_support then
    local node, expanded = self:toggle_node({
      id = ids.section(entry.key_name, 'tables'),
      type = 'tables',
      label = string.format('Tables (%d)', #entry.tables),
      key_name = entry.key_name,
    })
    if expanded then
      node.children = self:build_tables(entry.tables, entry, '')
    end
    return node
  end
  local node, expanded = self:toggle_node({
    id = ids.section(entry.key_name, 'schemas'),
    type = 'schemas',
    label = string.format('Schemas (%d)', #entry.schemas.list),
    key_name = entry.key_name,
  })
  if not expanded then
    return node
  end
  node.children = {}
  for _, schema in ipairs(entry.schemas.list) do
    local tables = entry.schemas.items[schema]
    local schema_node, schema_expanded = self:toggle_node({
      id = ids.schema(entry.key_name, schema),
      type = 'schema',
      label = string.format('%s (%d)', schema, #tables),
      key_name = entry.key_name,
    })
    if schema_expanded then
      schema_node.children = self:build_tables(tables, entry, schema)
    end
    node.children[#node.children + 1] = schema_node
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
      return acc + #(entry.routines.items[schema] or {})
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
  local node, expanded = self:toggle_node({
    id = ids.section(entry.key_name, 'routines'),
    type = 'routines',
    icon = 'procedures',
    label = string.format('Procedures (%d)', total),
    key_name = entry.key_name,
  })
  if not expanded then
    return node
  end
  if entry.schema_support then
    node.children = {}
    for _, schema in ipairs(routines.list) do
      local schema_routines = routines.items[schema]
      local schema_node, schema_expanded = self:toggle_node({
        id = ids.routine_schema(entry.key_name, schema),
        type = 'routine_schema',
        label = string.format('%s (%d)', schema, #schema_routines),
        key_name = entry.key_name,
      })
      if schema_expanded then
        schema_node.children = vim
          .iter(schema_routines)
          :map(function(routine)
            return self:build_routine(entry, routine, schema)
          end)
          :totable()
      end
      node.children[#node.children + 1] = schema_node
    end
  else
    node.children = vim
      .iter(routines.flat)
      :map(function(routine)
        return self:build_routine(entry, routine, '')
      end)
      :totable()
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
  -- The helper order is per-connection, not per-table: computed once for the
  -- first expanded table and reused.
  local ordered
  return vim
    .iter(list)
    :map(function(table_name)
      local node, expanded = self:toggle_node({
        id = ids.table(entry.key_name, schema, table_name),
        type = 'table',
        label = table_name,
        key_name = entry.key_name,
        extra = { table = table_name, schema = schema },
      })
      if expanded then
        ordered = ordered or table_helpers.ordered_names(entry.table_helpers, self.config.table_helpers_order)
        node.children = vim
          .iter(ordered)
          :map(function(helper_name)
            return {
              label = helper_name,
              icon = self.icons.tables,
              type = 'table_helper',
              action = 'open',
              key_name = entry.key_name,
              table = table_name,
              schema = schema,
              content = entry.table_helpers[helper_name],
            }
          end)
          :totable()
      end
      return node
    end)
    :totable()
end

return Drawer
