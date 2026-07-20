-- Postgres EXPLAIN (FORMAT JSON) -> normalized DadbodUI.ExplainPlan
--
-- Postgres emits a one-element JSON array: `[{ "Plan": {...}, "Planning Time":
-- ..., "Execution Time": ... }]`, where each plan node nests its children under
-- `Plans`. The mapping to `DadbodUI.PlanNode` is mostly field renames; the two
-- judgment calls are (a) folding `Join Type` into the operation name the way
-- postgres's own text format does ('Hash Left Join', 'Nested Loop Semi Join'),
-- and (b) which per-node keys count as headline expressions (`exprs`) vs
-- detail-float trivia (left in `raw`).

local M = {}

---@private
--- The per-node keys surfaced as (label, text) expression pairs, in display
--- order: conditions first (they explain the node), then the clause-shaped
--- keys. Everything else stays in `raw` for the detail float. `Sort Key` /
--- `Group Key` arrive as arrays and are joined for display.
local EXPR_KEYS = {
  'Index Cond',
  'Recheck Cond',
  'Hash Cond',
  'Merge Cond',
  'Join Filter',
  'Filter',
  'Sort Key',
  'Group Key',
}

---@private
--- The operation name, with the join type folded in like postgres's text
--- format: 'Hash Join'+Left -> 'Hash Left Join', 'Nested Loop'+Anti ->
--- 'Nested Loop Anti Join'. Inner joins stay bare -- that is the default and
--- the text format omits it too.
---@param raw table
---@return string
local function op_name(raw)
  local op = raw['Node Type'] or 'Unknown'
  local join_type = raw['Join Type']
  if type(join_type) ~= 'string' or join_type == 'Inner' then
    return op
  end
  local folded, hits = op:gsub('Join', join_type .. ' Join')
  if hits > 0 then
    return folded
  end
  return op .. ' ' .. join_type .. ' Join'
end

---@private
--- `vim.json.decode` maps JSON null to `vim.NIL`; normalize it (and wrong
--- types) to absent so downstream `~= nil` checks mean "the field is real".
---@param value any
---@param expected type
---@return any
local function field(value, expected)
  if type(value) ~= expected then
    return nil
  end
  return value
end

---@private
---@param raw table
---@return DadbodUI.PlanNode
local function to_node(raw)
  local exprs = {}
  for _, key in ipairs(EXPR_KEYS) do
    local value = raw[key]
    if type(value) == 'string' or type(value) == 'table' then
      -- Sort Key / Group Key arrive as arrays; join them for display.
      exprs[#exprs + 1] = { key, type(value) == 'table' and table.concat(value, ', ') or value }
    end
  end
  local node = {
    op = op_name(raw),
    relation = field(raw['Relation Name'], 'string'),
    alias = field(raw['Alias'], 'string'),
    cte_name = field(raw['CTE Name'], 'string'),
    subplan_name = field(raw['Subplan Name'], 'string'),
    index_name = field(raw['Index Name'], 'string'),
    startup_cost = field(raw['Startup Cost'], 'number'),
    total_cost = field(raw['Total Cost'], 'number'),
    plan_rows = field(raw['Plan Rows'], 'number'),
    actual_rows = field(raw['Actual Rows'], 'number'),
    actual_time_ms = field(raw['Actual Total Time'], 'number'),
    loops = field(raw['Actual Loops'], 'number'),
    exprs = exprs,
    children = {},
    raw = raw,
  }
  for _, child in ipairs(field(raw['Plans'], 'table') or {}) do
    node.children[#node.children + 1] = to_node(child)
  end
  return node
end

--- Parse decoded EXPLAIN (FORMAT JSON) output. Accepts the standard
--- one-element array or a bare `{ Plan = ... }` object (some proxies unwrap
--- the array). Returns `nil, err` when the shape carries no `Plan`.
---@param decoded any  the `vim.json.decode` result
---@return DadbodUI.ExplainPlan|nil plan
---@return string|nil err
function M.parse(decoded)
  local entry = decoded
  if type(entry) == 'table' and type(entry[1]) == 'table' then
    entry = entry[1]
  end
  local raw_plan = type(entry) == 'table' and field(entry['Plan'], 'table') or nil
  if raw_plan == nil then
    return nil, 'unexpected EXPLAIN JSON shape: no Plan object'
  end
  local root = to_node(raw_plan)
  return {
    root = root,
    planning_ms = field(entry['Planning Time'], 'number'),
    execution_ms = field(entry['Execution Time'], 'number'),
    analyzed = root.actual_time_ms ~= nil or root.actual_rows ~= nil,
  }
end

return M
