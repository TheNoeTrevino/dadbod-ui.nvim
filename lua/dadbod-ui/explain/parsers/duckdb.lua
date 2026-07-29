-- DuckDB EXPLAIN (FORMAT JSON) -> normalized DadbodUI.ExplainPlan
--
-- Two shapes land here (verified against duckdb v1.5.x). Plain
-- `EXPLAIN (FORMAT JSON)` is a one-element array of uniform
-- `{ name, extra_info, children }` nodes -- but the shell prints a box-art
-- `Physical Plan` banner before the JSON in EVERY output mode, so `clean`
-- strips it pre-decode. `EXPLAIN (ANALYZE, FORMAT JSON)` is bare JSON with a
-- different shape: a query-level profile object (latency, cpu_time) wrapping
-- an EXPLAIN_ANALYZE operator node above the real root, nodes spelled
-- `operator_*` with timings in SECONDS. Everything descriptive rides in
-- `extra_info` as strings -- even estimates ('Estimated Cardinality': '200').
--
-- Known wart: EXPLAIN (ANALYZE, FORMAT JSON) of INSERT makes the profiler
-- emit `{"result": "error"}` while the INSERT still executes. That surfaces
-- as a parse error here; the json_analyze template's ROLLBACK wrapper is what
-- undoes the statement.

local M = {}

---@private
--- The shared vim.NIL / wrong-type -> nil normalizer (dadbod-ui.explain.plan).
local field = require('dadbod-ui.explain.plan').field

---@private
--- The `extra_info` keys surfaced as (label, text) expression pairs, in
--- display order: conditions first, then the clause-shaped keys. Everything
--- else (Projections, Estimated Cardinality, ...) stays in `raw` for the
--- detail float. `Filters` arrives as an array and is joined for display.
local EXPR_KEYS = {
  'Conditions',
  'Filters',
  'Order By',
  'Top',
}

---@private
--- 'SEQ_SCAN' -> 'Seq Scan', 'RIGHT_SEMI' -> 'Right Semi': readable labels
--- for duckdb's SHOUTING_SNAKE operator names and join types.
---@param text string
---@return string
local function prettify(text)
  return (
    text:gsub('_', ' '):gsub('%a+', function(word)
      return word:sub(1, 1):upper() .. word:sub(2):lower()
    end)
  )
end

---@private
--- The operation name, prettified, with a non-inner join type folded in the
--- way the postgres parser does: 'HASH_JOIN' + LEFT -> 'Hash Left Join'.
---@param name string
---@param extra table
---@return string
local function op_name(name, extra)
  local op = prettify(name)
  local join_type = field(extra['Join Type'], 'string')
  if join_type == nil or join_type == 'INNER' then
    return op
  end
  local folded, hits = op:gsub('Join', prettify(join_type) .. ' Join')
  if hits > 0 then
    return folded
  end
  return op .. ' ' .. prettify(join_type) .. ' Join'
end

---@private
---@param extra table
---@return [string, string][]
local function exprs_of(extra)
  local exprs = {}
  for _, key in ipairs(EXPR_KEYS) do
    local value = extra[key]
    if type(value) == 'string' or type(value) == 'table' then
      exprs[#exprs + 1] = { key, type(value) == 'table' and table.concat(value, ', ') or value }
    end
  end
  return exprs
end

---@private
--- The detail payload: the node's own scalar keys flattened together with its
--- `extra_info` -- the detail float shows detail, never structure.
---@param raw table
---@param extra table
---@return table
local function detail_of(raw, extra)
  local detail = {}
  for key, value in pairs(raw) do
    if key ~= 'children' and key ~= 'extra_info' then
      detail[key] = value
    end
  end
  for key, value in pairs(extra) do
    detail[key] = value
  end
  return detail
end

---@private
--- One node of the plain (estimate-only) shape: `name` + `extra_info`, all
--- estimates as strings. No costs and no timings exist in this shape.
---@param raw table
---@return DadbodUI.PlanNode
local function plain_node(raw)
  local extra = field(raw.extra_info, 'table') or {}
  local node = {
    op = op_name(field(raw.name, 'string') or 'Unknown', extra),
    relation = field(extra.Table, 'string'),
    plan_rows = tonumber(extra['Estimated Cardinality']),
    exprs = exprs_of(extra),
    children = {},
    raw = detail_of(raw, extra),
  }
  for _, child in ipairs(field(raw.children, 'table') or {}) do
    node.children[#node.children + 1] = plain_node(child)
  end
  return node
end

---@private
--- One node of the analyze-profile shape. `cpu_time` is seconds and
--- CUMULATIVE (a node includes its children), the same shape as postgres
--- totals -- so the shared exclusive-time math applies unchanged.
--- (`operator_timing`, the node's own time, stays visible in `raw`.)
---@param raw table
---@return DadbodUI.PlanNode
local function analyze_node(raw)
  local extra = field(raw.extra_info, 'table') or {}
  local name = field(raw.operator_name, 'string') or field(raw.operator_type, 'string') or 'Unknown'
  local cpu_s = field(raw.cpu_time, 'number')
  local node = {
    op = op_name(name, extra),
    relation = field(extra.Table, 'string'),
    plan_rows = tonumber(extra['Estimated Cardinality']),
    actual_rows = field(raw.operator_cardinality, 'number'),
    actual_time_ms = cpu_s ~= nil and cpu_s * 1000 or nil,
    exprs = exprs_of(extra),
    children = {},
    raw = detail_of(raw, extra),
  }
  for _, child in ipairs(field(raw.children, 'table') or {}) do
    node.children[#node.children + 1] = analyze_node(child)
  end
  return node
end

--- Strip everything before the JSON document: the duckdb shell prints the
--- box-art `Physical Plan` banner ahead of plain EXPLAIN (FORMAT JSON) output
--- in every output mode. (The banner is box-drawing characters and letters,
--- so the first `[` or `{` byte is always the document.)
---@param raw string
---@return string
function M.clean(raw)
  local start = raw:find('[%[{]')
  if start == nil then
    return raw
  end
  return raw:sub(start)
end

--- Parse decoded EXPLAIN (FORMAT JSON) / EXPLAIN (ANALYZE, FORMAT JSON)
--- output. Returns `nil, err` when the JSON carries no plan -- including
--- duckdb's `{"result": "error"}` profiler wart.
---@param decoded any  the `vim.json.decode` result
---@return DadbodUI.ExplainPlan|nil plan
---@return string|nil err
function M.parse(decoded)
  if type(decoded) ~= 'table' then
    return nil, 'unexpected EXPLAIN JSON shape: not a plan'
  end
  if field(decoded.result, 'string') == 'error' then
    return nil, 'duckdb produced no JSON plan for this statement (its profiler reports an error for analyzed INSERTs)'
  end
  -- The analyze profile: a query-level object wrapping the EXPLAIN_ANALYZE
  -- operator above the real root.
  if field(decoded.query_name, 'string') ~= nil or field(decoded.latency, 'number') ~= nil then
    local top = (field(decoded.children, 'table') or {})[1]
    if type(top) == 'table' and field(top.operator_type, 'string') == 'EXPLAIN_ANALYZE' then
      top = (field(top.children, 'table') or {})[1]
    end
    if type(top) ~= 'table' then
      return nil, 'unexpected EXPLAIN ANALYZE JSON shape: no operator tree'
    end
    local latency_s = field(decoded.latency, 'number')
    return {
      root = analyze_node(top),
      execution_ms = latency_s ~= nil and latency_s * 1000 or nil,
      analyzed = true,
    }
  end
  -- Plain: a one-element array of physical-plan nodes.
  local entry = field(decoded[1], 'table') or decoded
  if field(entry.name, 'string') == nil then
    return nil, 'unexpected EXPLAIN JSON shape: no physical plan node'
  end
  return { root = plain_node(entry), analyzed = false }
end

return M
