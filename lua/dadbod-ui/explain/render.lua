-- Explain tree rendering (pure: PlanNode tree -> rows + highlight ranges)
--
-- The buffer-free half of the explain tree, mirroring the drawer's
-- `build_content` / `paint` purity split: `rows` maps an annotated
-- `DadbodUI.ExplainPlan` to display rows -- line text plus exact byte-range
-- highlights -- and the window module only writes them. Line N-1 of the buffer
-- is `rows[N]`, so the cursor row IS the plan node; that mapping is what the
-- node-detail float keys on.
--
-- A row reads as cells separated by a dim ` · `:
--
--   ├─ Seq Scan on orders o · Filter: (status = 'open') · rows 1000 · 850ms 94%
--
-- op + target (what ran, on what), the node's conditions (truncated; the full
-- text lives in the detail float), rows (with the estimate + skew marker when
-- the planner misjudged), and the node's OWN time (exclusive of children) with
-- its share of the whole plan -- the DBeaver-style percentage that finds the
-- expensive node without reading every line. Plain (non-ANALYZE) plans show
-- planner cost instead of time.

---@class DadbodUI.ExplainRow
---@field node? DadbodUI.PlanNode  the plan node this line renders; nil for the summary header
---@field id? string  stable tree-path id ('1.2.1') for this node -- what the collapse map keys on. View-owned: derived here during the walk, never written onto the plan model (same rule as the drawer's ids)
---@field line string
---@field highlights DadbodUI.Highlight[]

---@class DadbodUI.ExplainRenderOpts
---@field collapsed? table<string, boolean>  row id -> hidden children
---@field heat? { warn: number, hot: number }  exclusive-share thresholds for the warm/hot tiers
---@field skew_threshold? number  actual/estimated row ratio that flags a misestimate
---@field collapsed_icon? string  fold marker for a collapsed subtree (the resolved `icons.collapsed.explain`)

local M = {}

---@private
local DEFAULT_HEAT = { warn = 0.2, hot = 0.5 }
---@private
local DEFAULT_SKEW = 100
---@private
--- Byte budget for the inline conditions cell; the full text lives in the
--- node-detail float.
local EXPR_BUDGET = 60

---@private
--- Compact human count: 12345 -> '12.3k', 5000000 -> '5.0M'; smaller counts stay exact.
---@param n number
---@return string
local function fmt_count(n)
  if n >= 1e6 then
    return string.format('%.1fM', n / 1e6)
  end
  if n >= 1e4 then
    return string.format('%.1fk', n / 1e3)
  end
  return string.format('%d', n)
end

---@private
--- Compact duration: sub-ms keeps two decimals, seconds one.
---@param ms number
---@return string
local function fmt_ms(ms)
  if ms >= 1000 then
    return string.format('%.1fs', ms / 1000)
  end
  if ms < 1 then
    return string.format('%.2fms', ms)
  end
  if ms < 10 then
    return string.format('%.1fms', ms)
  end
  return string.format('%.0fms', ms)
end

---@private
--- The heat highlight group for a node's exclusive share of the plan.
---@param frac number|nil
---@param heat { warn: number, hot: number }
---@return string
local function heat_group(frac, heat)
  if frac == nil or frac < 0.05 then
    return 'DadbodUIExplainCold'
  end
  if frac >= heat.hot then
    return 'DadbodUIExplainHot'
  end
  if frac >= heat.warn then
    return 'DadbodUIExplainWarm'
  end
  return 'DadbodUIExplainMild'
end

---@private
--- What the node ran against: 'on orders o', 'on cte recent_orders',
--- 'using users_pkey' folded in for index scans. Empty for structural nodes.
---@param node DadbodUI.PlanNode
---@return string
local function target_text(node)
  local parts = {}
  if node.cte_name ~= nil then
    parts[#parts + 1] = 'on cte ' .. node.cte_name
  elseif node.relation ~= nil then
    local name = node.relation
    if node.alias ~= nil and node.alias ~= node.relation then
      name = name .. ' ' .. node.alias
    end
    parts[#parts + 1] = 'on ' .. name
  end
  if node.index_name ~= nil then
    parts[#parts + 1] = 'using ' .. node.index_name
  end
  return table.concat(parts, ' ')
end

---@private
--- The inline conditions cell: every expression pair joined, truncated to the
--- byte budget on a UTF-8 boundary with an ellipsis.
---@param node DadbodUI.PlanNode
---@return string
local function exprs_text(node)
  if #node.exprs == 0 then
    return ''
  end
  local parts = {}
  for _, pair in ipairs(node.exprs) do
    parts[#parts + 1] = pair[1] .. ': ' .. pair[2]
  end
  local text = table.concat(parts, ' · ')
  if #text > EXPR_BUDGET then
    -- Cut on a UTF-8 boundary: str_utf_start is 0 on a lead byte, negative inside
    -- a multibyte character.
    text = text:sub(1, EXPR_BUDGET + vim.str_utf_start(text, EXPR_BUDGET + 1)) .. '…'
  end
  return text
end

---@private
--- Append `text` under `group` to the line being assembled, tracking byte
--- columns so highlight ranges are exact by construction.
---@param acc { text: string[], hls: DadbodUI.Highlight[], col: integer }
---@param text string
---@param group string|nil
local function cell(acc, text, group)
  if text == '' then
    return
  end
  acc.text[#acc.text + 1] = text
  if group ~= nil then
    acc.hls[#acc.hls + 1] = { group = group, col_start = acc.col, col_end = acc.col + #text }
  end
  acc.col = acc.col + #text
end

---@private
local SEP = ' · '

---@private
--- Render one node into a row. `branch` is the accumulated tree-glyph prefix
--- for this node's line; `marker` its own connector (`├─ `/`└─ `); `id` the
--- view-derived tree path.
---@param node DadbodUI.PlanNode
---@param id string
---@param branch string
---@param marker string
---@param analyzed boolean
---@param opts { collapsed: table<string, boolean>, heat: { warn: number, hot: number }, skew_threshold: number, collapsed_icon: string }
---@return DadbodUI.ExplainRow
local function row_for(node, id, branch, marker, analyzed, opts)
  local acc = { text = {}, hls = {}, col = 0 }
  cell(acc, branch .. marker, 'DadbodUIExplainTree')
  if #node.children > 0 and opts.collapsed[id] then
    cell(acc, opts.collapsed_icon .. ' ', 'DadbodUIExplainTree')
  end
  cell(acc, node.op, 'DadbodUIExplainOp')
  local target = target_text(node)
  if target ~= '' then
    cell(acc, ' ', nil)
    cell(acc, target, 'DadbodUIExplainTarget')
  end
  local exprs = exprs_text(node)
  if exprs ~= '' then
    cell(acc, SEP, 'DadbodUIExplainTree')
    cell(acc, exprs, 'DadbodUIExplainExpr')
  end

  -- rows cell: actuals when analyzed (with the estimate called out on a
  -- misestimate), the planner's ~estimate otherwise.
  local rows_text
  if analyzed and node.actual_rows ~= nil then
    rows_text = 'rows ' .. fmt_count(node.actual_rows * (node.loops or 1))
  elseif node.plan_rows ~= nil then
    rows_text = 'rows ~' .. fmt_count(node.plan_rows)
  end
  if rows_text ~= nil then
    cell(acc, SEP, 'DadbodUIExplainTree')
    cell(acc, rows_text, 'DadbodUIExplainRows')
    if node.skew ~= nil and node.skew >= opts.skew_threshold then
      cell(acc, string.format(' (est %s ⚠×%d)', fmt_count(node.plan_rows), node.skew), 'DadbodUIExplainSkew')
    end
  end

  -- time/cost cell: the node's OWN work (exclusive of children) and its share
  -- of the whole plan -- one shared tail, only the value text differs.
  local value
  if analyzed and node.exclusive_ms ~= nil then
    value = fmt_ms(node.exclusive_ms)
  elseif not analyzed and node.total_cost ~= nil then
    value = string.format('cost %.0f', node.total_cost)
  end
  if value ~= nil then
    cell(acc, SEP, 'DadbodUIExplainTree')
    local share = node.frac ~= nil and string.format(' %d%%', math.floor(node.frac * 100 + 0.5)) or ''
    cell(acc, value .. share, heat_group(node.frac, opts.heat))
  end

  return { node = node, id = id, line = table.concat(acc.text), highlights = acc.hls }
end

---@private
--- Depth-first emit of `node` and its visible children. The branch prefix
--- grows `│  ` under a non-last ancestor and `   ` under a last one -- the
--- standard tree-drawing recurrence.
---@param node DadbodUI.PlanNode
---@param id string
---@param branch string
---@param marker string
---@param analyzed boolean
---@param opts { collapsed: table<string, boolean>, heat: { warn: number, hot: number }, skew_threshold: number, collapsed_icon: string }
---@param out DadbodUI.ExplainRow[]
local function emit(node, id, branch, marker, analyzed, opts, out)
  out[#out + 1] = row_for(node, id, branch, marker, analyzed, opts)
  if opts.collapsed[id] then
    return
  end
  local child_branch = branch
  if marker ~= '' then
    child_branch = branch .. (marker:find('└') == 1 and '   ' or '│  ')
  end
  for i, child in ipairs(node.children) do
    emit(child, id .. '.' .. i, child_branch, i == #node.children and '└─ ' or '├─ ', analyzed, opts, out)
  end
end

---@private
--- The one-line plan summary shown above the tree.
---@param plan DadbodUI.ExplainPlan
---@return DadbodUI.ExplainRow
local function header_row(plan)
  local parts = {}
  if plan.planning_ms ~= nil then
    parts[#parts + 1] = 'planning ' .. fmt_ms(plan.planning_ms)
  end
  if plan.execution_ms ~= nil then
    parts[#parts + 1] = 'execution ' .. fmt_ms(plan.execution_ms)
  end
  parts[#parts + 1] = plan.analyzed and 'analyzed' or 'estimates only'
  local line = table.concat(parts, SEP)
  return { line = line, highlights = { { group = 'DadbodUIExplainSummary', col_start = 0, col_end = #line } } }
end

--- Render an annotated plan to display rows: a summary header, a blank
--- spacer, then one row per visible plan node. Pure -- collapse state, heat
--- thresholds and the skew flag all arrive in `opts`.
---@param plan DadbodUI.ExplainPlan
---@param opts? DadbodUI.ExplainRenderOpts
---@return DadbodUI.ExplainRow[]
function M.rows(plan, opts)
  opts = opts or {}
  local resolved = {
    collapsed = opts.collapsed or {},
    heat = opts.heat or DEFAULT_HEAT,
    skew_threshold = opts.skew_threshold or DEFAULT_SKEW,
    collapsed_icon = opts.collapsed_icon or '▸',
  }
  local out = { header_row(plan), { line = '', highlights = {} } }
  emit(plan.root, '1', '', '', plan.analyzed, resolved, out)
  return out
end

return M
