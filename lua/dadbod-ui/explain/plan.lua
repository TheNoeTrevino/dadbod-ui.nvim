-- Normalized explain-plan model (decode + derived metrics)
--
-- The bridge hands back whatever the adapter's CLI printed for
-- `EXPLAIN (FORMAT JSON)`; this module turns that raw text into the one
-- dialect-agnostic `DadbodUI.ExplainPlan` shape the tree renderer consumes.
-- Per-dialect JSON shapes live in
-- `explain/parsers/<adapter>.lua` (postgres's `Plan`/`Plans` nesting, mysql's
-- `query_block`); this module owns only dispatch, decode, and the derived
-- metrics -- so downstream code never branches on adapter.
--
-- Derived metrics are what make a plan readable at a glance:
--   * exclusive time/cost -- a node's total minus its children's, i.e. the work
--     the node itself did. Root totals are cumulative, so the slow node is the
--     one with the big EXCLUSIVE number, not the big total.
--   * frac -- exclusive share of the root total (time when ANALYZE ran, cost
--     otherwise): the renderer's heat signal.
--   * skew -- actual/estimated row ratio: the planner-misestimate signal (stale
--     statistics) that usually explains WHY a bad plan was chosen.

---@private
local adapters = require('dadbod-ui.adapters')

local M = {}

---@private
--- Canonical adapter name -> parser module. A scheme absent here has no
--- structured-plan parser even if it has a `json` template; `decode` reports it
--- honestly instead of guessing at the shape.
local parsers = {
  postgres = 'dadbod-ui.explain.parsers.postgres',
}

---@private
--- Fill the derived metrics fields on every node, bottom-up. Clamped at zero:
--- dialects don't always include every child's contribution in the parent's
--- total (postgres InitPlans, parallel workers), and a negative "own time" is
--- noise, not signal.
---@param node DadbodUI.PlanNode
local function compute(node)
  local child_ms, child_cost = 0, 0
  for _, child in ipairs(node.children) do
    compute(child)
    child_ms = child_ms + (child.total_ms or 0)
    child_cost = child_cost + (child.total_cost or 0)
  end
  if node.actual_time_ms ~= nil then
    node.total_ms = node.actual_time_ms * (node.loops or 1)
    node.exclusive_ms = math.max(node.total_ms - child_ms, 0)
  end
  if node.total_cost ~= nil then
    node.exclusive_cost = math.max(node.total_cost - child_cost, 0)
  end
  if node.plan_rows ~= nil and node.plan_rows > 0 and node.actual_rows ~= nil then
    node.skew = (node.actual_rows * (node.loops or 1)) / node.plan_rows
  end
end

---@private
---@param node DadbodUI.PlanNode
---@param visit fun(node: DadbodUI.PlanNode)
local function walk(node, visit)
  visit(node)
  for _, child in ipairs(node.children) do
    walk(child, visit)
  end
end

--- Fill the derived metrics (`total_ms`, `exclusive_*`, `frac`, `skew`) on
--- every node of `plan`. Called by `decode`; exposed for parsers-in-tests.
---@param plan DadbodUI.ExplainPlan
---@return DadbodUI.ExplainPlan
function M.annotate(plan)
  local root = plan.root
  compute(root)
  -- Heat denominator: real time when the plan was analyzed, planner cost
  -- otherwise -- whichever the whole tree consistently carries.
  local denom_ms = root.total_ms
  local denom_cost = root.total_cost
  walk(root, function(node)
    if denom_ms ~= nil and denom_ms > 0 and node.exclusive_ms ~= nil then
      node.frac = node.exclusive_ms / denom_ms
    elseif denom_cost ~= nil and denom_cost > 0 and node.exclusive_cost ~= nil then
      node.frac = node.exclusive_cost / denom_cost
    end
  end)
  return plan
end

--- Whether `scheme` has a structured-plan parser (stricter than
--- `explain.supports_json`: a template without a parser renders nothing).
---@param scheme string
---@return boolean
function M.supports(scheme)
  return parsers[adapters.canonical(scheme) or ''] ~= nil
end

--- Decode the raw CLI output of a JSON EXPLAIN into an annotated plan.
--- Returns `nil, err` (user-facing) when the scheme has no parser, the output
--- is not valid JSON (e.g. the server reported an error instead of a plan), or
--- the JSON is not shaped like a plan.
---@param scheme string
---@param raw string  the client's stdout, as captured by the bridge
---@return DadbodUI.ExplainPlan|nil plan
---@return string|nil err
function M.decode(scheme, raw)
  local canonical = adapters.canonical(scheme)
  local parser = canonical and parsers[canonical] or nil
  if parser == nil then
    return nil, string.format('no structured plan parser for adapter %s', tostring(canonical or scheme))
  end
  local ok, decoded = pcall(vim.json.decode, vim.trim(raw or ''))
  if not ok or type(decoded) ~= 'table' then
    return nil, 'could not decode EXPLAIN JSON output: ' .. vim.trim(raw or ''):sub(1, 200)
  end
  local plan, err = require(parser).parse(decoded)
  if plan == nil then
    return nil, err
  end
  return M.annotate(plan)
end

return M
