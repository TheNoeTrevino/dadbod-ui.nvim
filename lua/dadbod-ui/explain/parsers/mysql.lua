-- MySQL / MariaDB EXPLAIN FORMAT=JSON -> normalized DadbodUI.ExplainPlan
--
-- Both dialects nest the plan inside `query_block`, but the shape is a
-- keyed object tree, not postgres's uniform `Plans` array: wrapper keys
-- (`ordering_operation`, `grouping_operation`, `nested_loop`, subquery
-- lists) hold the structure, and `table` objects are the leaves. The two
-- dialects also spell fields differently (MySQL `rows_examined_per_scan` +
-- string costs in `cost_info`; MariaDB `rows` + `r_*` actuals from
-- `ANALYZE FORMAT=JSON`), so the normalizer reads both spellings and takes
-- whichever exists.
--
-- Actuals: only MariaDB has them in JSON (`r_rows`/`r_total_time_ms` --
-- MySQL's EXPLAIN ANALYZE emits TREE text, not JSON). MariaDB's
-- `r_total_time_ms` is already the total across loops, so it lands as
-- `actual_time_ms` with loops=1 -- the shared exclusive-time math then works
-- unchanged (`r_loops` stays visible in `raw`).

local M = {}

---@private
--- Wrapper keys that hold nested plan structure, with display names and the
--- order children render in (fixed order keeps the tree stable across runs --
--- pairs() iteration is not deterministic).
local WRAPPERS = {
  { 'table', nil }, -- leaf scans; op derived from access_type
  { 'query_block', 'Query' },
  { 'nested_loop', 'Nested Loop' },
  -- MySQL spellings.
  { 'ordering_operation', 'Sort' },
  { 'grouping_operation', 'Group' },
  { 'duplicates_removal', 'Distinct' },
  { 'windowing', 'Window' },
  { 'materialized_from_subquery', 'Materialize' },
  { 'buffer_result', 'Buffer' },
  { 'union_result', 'Union' },
  { 'query_specifications', 'Query' },
  { 'attached_subqueries', 'Subquery' },
  { 'select_list_subqueries', 'Subquery' },
  { 'having_subqueries', 'Subquery' },
  { 'order_by_subqueries', 'Subquery' },
  { 'group_by_subqueries', 'Subquery' },
  { 'insert_from', 'Insert From' },
  -- MariaDB spellings (its optimizer trace never uses MySQL's *_operation keys).
  { 'filesort', 'Sort' },
  { 'temporary_table', 'Temporary' },
  { 'read_sorted_file', 'Read Sorted' },
  { 'block-nl-join', 'Block Nested Loop' },
  { 'range-checked-for-each-record', 'Range Check' },
  { 'expression_cache', 'Expression Cache' },
  { 'subqueries', 'Subquery' },
}

---@private
--- Wrapper-key lookup set, for the unknown-key safety net below.
local KNOWN = {}
for _, spec in ipairs(WRAPPERS) do
  KNOWN[spec[1]] = true
end

---@private
--- Whether an UNKNOWN key's value looks like nested plan structure -- the
--- safety net for dialect spellings this table hasn't met: better a child
--- named after the raw key than a silently truncated tree.
---@param value any
---@return boolean
local function looks_like_plan(value)
  if type(value) ~= 'table' then
    return false
  end
  local probe = value[1] ~= nil and value[1] or value
  return type(probe) == 'table'
    and (probe.table ~= nil or probe.query_block ~= nil or probe.access_type ~= nil or probe.nested_loop ~= nil)
end

---@private
--- 'block-nl-join' -> 'Block Nl Join': a readable label for an unknown key.
---@param key string
---@return string
local function prettify(key)
  return (key:gsub('[_%-]', ' '):gsub('%f[%a]%a', string.upper))
end

---@private
--- MySQL access_type -> a readable operation name (mirroring how the
--- postgres parser reports 'Seq Scan' / 'Index Scan').
local ACCESS = {
  ALL = 'Full Table Scan',
  index = 'Index Scan',
  range = 'Index Range Scan',
  ref = 'Ref Lookup',
  eq_ref = 'Unique Lookup',
  const = 'Const Lookup',
  system = 'System',
  fulltext = 'Fulltext Search',
  ref_or_null = 'Ref-or-NULL Lookup',
  index_merge = 'Index Merge',
  unique_subquery = 'Unique Subquery',
  index_subquery = 'Index Subquery',
}

---@private
--- The shared vim.NIL / wrong-type -> nil normalizer (dadbod-ui.explain.plan).
local field = require('dadbod-ui.explain.plan').field

---@private
--- Costs arrive as strings in MySQL's `cost_info`; MariaDB (>=10.11) has a
--- plain `cost` number on some nodes.
---@param raw table
---@return number|nil
local function cost_of(raw)
  local info = field(raw.cost_info, 'table')
  if info ~= nil then
    local cost = tonumber(info.prefix_cost) or tonumber(info.query_cost) or tonumber(info.read_cost)
    if cost ~= nil then
      return cost
    end
  end
  return field(raw.cost, 'number')
end

---@private
--- The (label, text) expression pairs a node surfaces inline.
---@param raw table
---@return [string, string][]
local function exprs_of(raw)
  local exprs = {}
  for _, spec in ipairs({
    { 'index_condition', 'Index Cond' },
    { 'attached_condition', 'Filter' },
    { 'having_condition', 'Having' },
  }) do
    local value = field(raw[spec[1]], 'string')
    if value ~= nil then
      exprs[#exprs + 1] = { spec[2], value }
    end
  end
  return exprs
end

---@private
---@type fun(key: string, op: string|nil, raw: table): DadbodUI.PlanNode
local to_node

---@private
--- Append `value`'s plan node(s) under `key` to `children`.
--- `nested_loop` is an ARRAY of operand wrappers (`{ table = {...} }`) -- it
--- becomes ONE join node whose children are the unwrapped operands. Subquery
--- lists fan out to one child per item, each item unwrapped when it is a pure
--- pass-through (`{ query_block = {...} }` with nothing of its own).
---@param key string
---@param op string
---@param value any
---@param children DadbodUI.PlanNode[]
local function add_children(key, op, value, children)
  if type(value) ~= 'table' then
    return
  end
  if value[1] == nil then
    children[#children + 1] = to_node(key, op, value)
    return
  end
  local items = {}
  for _, item in ipairs(value) do
    local node = to_node(key, op, item)
    -- nested_loop operands ({ table = {...} }) and union query_specifications
    -- ({ query_block = {...} }) are pure wrappers: unwrap their single child.
    -- Subquery-list items are NOT unwrapped -- their 'Subquery' label and raw
    -- scalars (dependent/cacheable) carry information.
    local unwrap = key == 'nested_loop' or key == 'query_specifications'
    if unwrap and node.op == op and #node.children == 1 and node.total_cost == nil and #node.exprs == 0 then
      items[#items + 1] = node.children[1]
    else
      items[#items + 1] = node
    end
  end
  if key == 'nested_loop' then
    -- Synthesized join node: the array it wraps is pure structure, so its
    -- detail payload is empty.
    children[#children + 1] = { op = op, exprs = {}, children = items, raw = {} }
  else
    vim.list_extend(children, items)
  end
end

---@private
--- Normalize one raw object into a PlanNode. `key`/`op` name what the object
--- IS (a wrapper's display name); `table` objects (op = nil) derive their op
--- from `access_type` instead.
---@param key string
---@param op string|nil
---@param raw table
---@return DadbodUI.PlanNode
---@diagnostic disable-next-line: cast-local-type
function to_node(key, op, raw)
  local node = {
    op = op or key,
    relation = nil,
    index_name = field(raw.key, 'string'),
    total_cost = cost_of(raw),
    plan_rows = field(raw.rows_examined_per_scan, 'number') or field(raw.rows, 'number'),
    exprs = exprs_of(raw),
    children = {},
    raw = raw,
  }
  if key == 'table' then
    node.relation = field(raw.table_name, 'string')
    local access = field(raw.access_type, 'string')
    node.op = access ~= nil and (ACCESS[access] or access) or 'Table'
  end
  -- MariaDB ANALYZE actuals: r_total_time_ms is the total across loops.
  -- Table nodes (MariaDB >= 10.9) split it into r_table_time_ms +
  -- r_other_time_ms instead -- sum them so scans still carry real time.
  local r_time = field(raw.r_total_time_ms, 'number')
  if r_time == nil then
    local r_table, r_other = field(raw.r_table_time_ms, 'number'), field(raw.r_other_time_ms, 'number')
    if r_table ~= nil or r_other ~= nil then
      r_time = (r_table or 0) + (r_other or 0)
    end
  end
  if r_time ~= nil then
    node.actual_time_ms = r_time
    node.loops = 1
  end
  node.actual_rows = field(raw.r_rows, 'number')

  for _, spec in ipairs(WRAPPERS) do
    local child_key, child_op = spec[1], spec[2]
    local value = raw[child_key]
    if child_key == 'table' then
      -- Only ever an object (nested_loop's array shape recurses via items).
      if key ~= 'table' and type(value) == 'table' and value[1] == nil then
        node.children[#node.children + 1] = to_node('table', nil, value)
      end
    else
      add_children(child_key, child_op, value, node.children)
    end
  end
  -- Safety net: an unknown key whose value is clearly nested plan structure
  -- still becomes a child (labeled from the key) instead of silently
  -- truncating the tree. Sorted for a deterministic child order.
  local unknown = {}
  for raw_key, value in pairs(raw) do
    if type(raw_key) == 'string' and not KNOWN[raw_key] and looks_like_plan(value) then
      unknown[#unknown + 1] = raw_key
    end
  end
  table.sort(unknown)
  for _, raw_key in ipairs(unknown) do
    add_children(raw_key, prettify(raw_key), raw[raw_key], node.children)
  end
  -- The detail payload: the node's own keys, minus everything that became a
  -- child above -- the detail float shows detail, never structure.
  node.raw = {}
  for raw_key, value in pairs(raw) do
    if not ((KNOWN[raw_key] and type(value) == 'table') or looks_like_plan(value)) then
      node.raw[raw_key] = value
    end
  end
  return node
end

--- Parse decoded EXPLAIN FORMAT=JSON output (MySQL 5.7+/8.x or MariaDB,
--- including MariaDB's ANALYZE FORMAT=JSON). Returns `nil, err` when the
--- JSON carries no `query_block`.
---@param decoded any  the `vim.json.decode` result
---@return DadbodUI.ExplainPlan|nil plan
---@return string|nil err
function M.parse(decoded)
  local query_block = type(decoded) == 'table' and field(decoded.query_block, 'table') or nil
  if query_block == nil then
    return nil, 'unexpected EXPLAIN JSON shape: no query_block object'
  end
  local root = to_node('query_block', 'Query', query_block)
  local analyzed = false
  local function scan(node)
    analyzed = analyzed or node.actual_time_ms ~= nil or node.actual_rows ~= nil
    for _, child in ipairs(node.children) do
      scan(child)
    end
  end
  scan(root)
  return { root = root, analyzed = analyzed }
end

return M
