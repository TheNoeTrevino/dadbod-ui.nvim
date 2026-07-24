-- Specs for the normalized plan model: postgres EXPLAIN (FORMAT JSON) parsing
-- into DadbodUI.PlanNode trees and the derived metrics (exclusive time/cost,
-- heat fraction, estimate skew) that make the tree readable. Fixtures are
-- captured-shape postgres output, inlined like the classifier specs.

local plan = require('dadbod-ui.explain.plan')

-- An ANALYZE'd plan: Limit -> Sort -> Hash Left Join -> (Seq Scan, Hash ->
-- Index Scan). The seq scan holds most of the real time; the sort misestimates
-- rows by 100x.
local ANALYZED = [=[
[
  {
    "Plan": {
      "Node Type": "Limit",
      "Startup Cost": 870.11, "Total Cost": 870.16,
      "Plan Rows": 20, "Actual Rows": 20,
      "Startup Time": 902.10, "Actual Total Time": 903.00, "Actual Loops": 1,
      "Plans": [
        {
          "Node Type": "Sort",
          "Startup Cost": 870.11, "Total Cost": 872.61,
          "Plan Rows": 10, "Actual Rows": 1000,
          "Actual Total Time": 902.80, "Actual Loops": 1,
          "Sort Key": ["o.created_at DESC"],
          "Plans": [
            {
              "Node Type": "Hash Join", "Join Type": "Left",
              "Hash Cond": "(o.user_id = u.id)",
              "Startup Cost": 33.38, "Total Cost": 860.00,
              "Plan Rows": 1000, "Actual Rows": 1000,
              "Actual Total Time": 880.00, "Actual Loops": 1,
              "Plans": [
                {
                  "Node Type": "Seq Scan",
                  "Parent Relationship": "Outer",
                  "Relation Name": "orders", "Alias": "o",
                  "Filter": "((o.status)::text = 'open'::text)",
                  "Rows Removed by Filter": 98999,
                  "Startup Cost": 0.00, "Total Cost": 820.00,
                  "Plan Rows": 1000, "Actual Rows": 1000,
                  "Actual Total Time": 850.00, "Actual Loops": 1
                },
                {
                  "Node Type": "Hash",
                  "Startup Cost": 21.00, "Total Cost": 21.00,
                  "Plan Rows": 300, "Actual Rows": 300,
                  "Actual Total Time": 4.00, "Actual Loops": 1,
                  "Plans": [
                    {
                      "Node Type": "Index Scan",
                      "Parent Relationship": "Inner",
                      "Relation Name": "users", "Alias": "u",
                      "Index Name": "users_pkey",
                      "Startup Cost": 0.15, "Total Cost": 20.00,
                      "Plan Rows": 300, "Actual Rows": 300,
                      "Actual Total Time": 3.50, "Actual Loops": 1
                    }
                  ]
                }
              ]
            }
          ]
        }
      ]
    },
    "Planning Time": 0.410,
    "Execution Time": 903.520
  }
]
]=]

-- A plain (no ANALYZE) plan: costs only, no actual measurements.
local PLAIN = [=[
[
  {
    "Plan": {
      "Node Type": "Seq Scan",
      "Relation Name": "contacts", "Alias": "contacts",
      "Startup Cost": 0.00, "Total Cost": 155.00,
      "Plan Rows": 5000
    },
    "Planning Time": 0.100
  }
]
]=]

describe('explain plan: decode (postgres)', function()
  it('parses the nested Plans into a normalized node tree', function()
    local parsed, err = plan.decode('postgresql', ANALYZED)
    assert.is_nil(err)
    assert.is_truthy(parsed)
    assert.is_true(parsed.analyzed)
    assert.equals(0.410, parsed.planning_ms)
    assert.equals(903.520, parsed.execution_ms)

    local root = parsed.root
    assert.equals('Limit', root.op)
    local sort = root.children[1]
    local join = sort.children[1]
    assert.equals('Sort', sort.op)
    assert.equals('Hash Left Join', join.op) -- Join Type folded like the text format
    local scan, hash = join.children[1], join.children[2]
    assert.equals('Seq Scan', scan.op)
    assert.equals('orders', scan.relation)
    assert.equals('o', scan.alias)
    assert.equals('users_pkey', hash.children[1].index_name)
  end)

  it('surfaces conditions and clause keys as ordered expression pairs', function()
    local parsed = plan.decode('postgres', ANALYZED)
    local sort = parsed.root.children[1]
    local join = sort.children[1]
    assert.same({ { 'Sort Key', 'o.created_at DESC' } }, sort.exprs)
    assert.same({ { 'Hash Cond', '(o.user_id = u.id)' } }, join.exprs)
    -- Non-expression keys (Rows Removed by Filter) stay in raw for the detail view.
    local scan = join.children[1]
    assert.same({ { 'Filter', "((o.status)::text = 'open'::text)" } }, scan.exprs)
    assert.equals(98999, scan.raw['Rows Removed by Filter'])
  end)

  it('derives exclusive time and heat fractions from an analyzed plan', function()
    local parsed = plan.decode('postgres', ANALYZED)
    local root = parsed.root
    local join = root.children[1].children[1]
    local scan = join.children[1]
    -- The join's own time excludes its children: 880 - (850 + 4).
    assert.is_true(math.abs(join.exclusive_ms - 26.0) < 1e-9)
    -- The seq scan is a leaf: exclusive == total, and it dominates the heat.
    assert.equals(850.0, scan.exclusive_ms)
    assert.is_true(scan.frac > 0.9)
    assert.is_true(root.children[1].frac < 0.1) -- the sort's own share is small
  end)

  it('derives estimate skew (actual/estimated rows)', function()
    local parsed = plan.decode('postgres', ANALYZED)
    local sort = parsed.root.children[1]
    assert.equals(100, sort.skew) -- 1000 actual vs 10 estimated
    assert.equals(1, sort.children[1].skew) -- the join estimate was exact
  end)

  it('falls back to cost fractions for a plain (no ANALYZE) plan', function()
    local parsed, err = plan.decode('postgres', PLAIN)
    assert.is_nil(err)
    assert.is_false(parsed.analyzed)
    local root = parsed.root
    assert.is_nil(root.total_ms)
    assert.is_nil(root.skew) -- no actuals to compare
    assert.equals(155.00, root.exclusive_cost)
    assert.equals(1, root.frac)
  end)

  it('errors on a scheme with no parser declared on its adapter spec', function()
    local parsed, err = plan.decode('sqlite', '[]')
    assert.is_nil(parsed)
    assert.is_truthy(err and err:match('no structured plan parser for adapter sqlite'))
  end)

  it('errors (with the offending output) when stdout is not JSON', function()
    local parsed, err = plan.decode('postgres', 'ERROR:  relation "nope" does not exist')
    assert.is_nil(parsed)
    assert.is_truthy(err and err:match('could not decode EXPLAIN JSON'))
    assert.is_truthy(err and err:match('relation "nope" does not exist'))
  end)

  it('errors on JSON that is not shaped like a plan', function()
    local parsed, err = plan.decode('postgres', '[{"rows": 3}]')
    assert.is_nil(parsed)
    assert.is_truthy(err and err:match('no Plan object'))
  end)
end)
