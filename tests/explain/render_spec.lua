-- Specs for the pure explain-tree renderer: PlanNode tree -> rows with line
-- text and exact byte-range highlights. Buffer-free by design (the window
-- module only writes what these functions return), mirroring highlights_spec.

local plan = require('dadbod-ui.explain.plan')
local render = require('dadbod-ui.explain.render')

-- Minimal analyzed plan: Sort over a Seq Scan, with a misestimate on the scan.
local ANALYZED = [=[
[
  {
    "Plan": {
      "Node Type": "Sort",
      "Sort Key": ["t.b"],
      "Startup Cost": 10.0, "Total Cost": 12.0,
      "Plan Rows": 1000, "Actual Rows": 1000,
      "Actual Total Time": 100.0, "Actual Loops": 1,
      "Plans": [
        {
          "Node Type": "Seq Scan",
          "Relation Name": "things", "Alias": "t",
          "Filter": "(t.a > 5)",
          "Startup Cost": 0.0, "Total Cost": 9.0,
          "Plan Rows": 10, "Actual Rows": 1000,
          "Actual Total Time": 90.0, "Actual Loops": 1
        }
      ]
    },
    "Planning Time": 0.2,
    "Execution Time": 101.0
  }
]
]=]

local PLAIN = [=[
[{"Plan": {
  "Node Type": "Hash Join", "Join Type": "Inner",
  "Hash Cond": "(a.id = b.id)",
  "Startup Cost": 1.0, "Total Cost": 100.0, "Plan Rows": 50,
  "Plans": [
    {"Node Type": "Seq Scan", "Relation Name": "a", "Alias": "a",
     "Startup Cost": 0.0, "Total Cost": 40.0, "Plan Rows": 50},
    {"Node Type": "Hash", "Startup Cost": 30.0, "Total Cost": 30.0, "Plan Rows": 50,
     "Plans": [
       {"Node Type": "Seq Scan", "Relation Name": "b", "Alias": "b",
        "Startup Cost": 0.0, "Total Cost": 29.0, "Plan Rows": 50}
     ]}
  ]
}}]
]=]

--- The row rendering `node_id`, or nil.
---@param rows DadbodUI.ExplainRow[]
---@param node_id string
local function row_by_id(rows, node_id)
  for _, row in ipairs(rows) do
    if row.node ~= nil and row.node.id == node_id then
      return row
    end
  end
end

--- The highlight group covering byte column `col` of `row`, or nil.
local function group_at(row, col)
  for _, hl in ipairs(row.highlights) do
    if col >= hl.col_start and col < hl.col_end then
      return hl.group
    end
  end
end

describe('explain render: rows', function()
  it('renders header, spacer, then one row per node with tree glyphs', function()
    local rows = render.rows(plan.decode('postgres', ANALYZED))
    assert.equals(4, #rows)
    assert.is_nil(rows[1].node)
    assert.is_truthy(rows[1].line:match('planning 0%.20ms'))
    assert.is_truthy(rows[1].line:match('execution 101ms'))
    assert.is_truthy(rows[1].line:match('analyzed'))
    assert.equals('', rows[2].line)
    assert.is_truthy(rows[3].line:match('^Sort'))
    assert.is_truthy(rows[4].line:match('^└─ Seq Scan on things t'))
  end)

  it('shows each node its OWN time and share, heat-tiered', function()
    local rows = render.rows(plan.decode('postgres', ANALYZED))
    local sort, scan = row_by_id(rows, '1'), row_by_id(rows, '1.1')
    -- Sort's own time is 100 - 90 = 10ms (10%); the scan holds 90ms (90%).
    assert.is_truthy(sort.line:match('10ms 10%%$'))
    assert.is_truthy(scan.line:match('90ms 90%%$'))
    assert.equals('DadbodUIExplainHot', group_at(scan, #scan.line - 1))
    assert.equals('DadbodUIExplainMild', group_at(sort, #sort.line - 1))
  end)

  it('flags a misestimate with the skew marker on the rows cell', function()
    local rows = render.rows(plan.decode('postgres', ANALYZED))
    local scan = row_by_id(rows, '1.1')
    assert.is_truthy(scan.line:match('rows 1000 %(est 10 ⚠×100%)'))
    local at = scan.line:find('%(est')
    assert.equals('DadbodUIExplainSkew', group_at(scan, at))
    -- No marker when the estimate held (the sort's rows were exact).
    assert.is_falsy(row_by_id(rows, '1').line:match('est'))
  end)

  it('renders inline conditions under the expr group, truncated to budget', function()
    local rows = render.rows(plan.decode('postgres', ANALYZED))
    local scan = row_by_id(rows, '1.1')
    local at = scan.line:find('Filter: %(t%.a > 5%)')
    assert.is_truthy(at)
    assert.equals('DadbodUIExplainExpr', group_at(scan, at - 1))
  end)

  it('falls back to cost cells (with ~estimate rows) for plain plans', function()
    local rows = render.rows(plan.decode('postgres', PLAIN))
    assert.is_truthy(rows[1].line:match('estimates only'))
    local join = row_by_id(rows, '1')
    assert.is_truthy(join.line:match('rows ~50'))
    assert.is_truthy(join.line:match('cost 100 30%%$')) -- own cost 100-70=30 of 100
    -- Inner joins render bare, like postgres's own text format.
    assert.is_truthy(join.line:match('^Hash Join'))
  end)

  it('draws continuation bars for non-last subtrees', function()
    local rows = render.rows(plan.decode('postgres', PLAIN))
    -- b's scan sits under Hash (last child), whose parent lists Hash last too.
    local inner = row_by_id(rows, '1.2.1')
    assert.is_truthy(inner.line:match('^   └─ Seq Scan on b'))
    local first = row_by_id(rows, '1.1')
    assert.is_truthy(first.line:match('^├─ Seq Scan on a'))
  end)

  it('collapses a subtree and marks the fold', function()
    local parsed = plan.decode('postgres', PLAIN)
    local rows = render.rows(parsed, { collapsed = { ['1.2'] = true } })
    assert.is_nil(row_by_id(rows, '1.2.1')) -- hidden child
    local hash = row_by_id(rows, '1.2')
    assert.is_truthy(hash.line:match('▸ Hash'))
  end)

  it('keeps highlight ranges within the line bytes', function()
    for _, fixture in ipairs({ ANALYZED, PLAIN }) do
      for _, row in ipairs(render.rows(plan.decode('postgres', fixture))) do
        for _, hl in ipairs(row.highlights) do
          assert.is_true(hl.col_start >= 0)
          assert.is_true(hl.col_end <= #row.line)
          assert.is_true(hl.col_start < hl.col_end)
        end
      end
    end
  end)
end)
