-- Specs for the DuckDB plan normalizer: the shell's box-art banner is
-- stripped pre-decode, the plain `{ name, extra_info, children }` array and
-- the analyze profile (`operator_*` fields, seconds, EXPLAIN_ANALYZE wrapper)
-- both land in the shared DadbodUI.PlanNode shape, and the profiler's
-- `{"result": "error"}` wart surfaces as an error instead of an empty tree.
-- Fixtures are real duckdb v1.5.5 output (the analyze one trimmed to the
-- fields that matter, spellings intact).

local plan = require('dadbod-ui.explain.plan')

-- EXPLAIN (FORMAT JSON) of a join + filter + ORDER BY ... LIMIT, exactly as
-- the CLI prints it: banner first, JSON after, in every output mode.
local PLAIN = [=[
┌─────────────────────────────┐
│┌───────────────────────────┐│
││       Physical Plan       ││
│└───────────────────────────┘│
└─────────────────────────────┘
[
    {
        "name": "TOP_N",
        "children": [
            {
                "name": "HASH_JOIN",
                "children": [
                    {
                        "name": "SEQ_SCAN",
                        "children": [],
                        "extra_info": {
                            "Table": "demo.main.users",
                            "Type": "Sequential Scan",
                            "Projections": ["org_id", "name"],
                            "Filters": ["id>500", "optional: Dynamic Filter (name)"],
                            "Estimated Cardinality": "200"
                        }
                    },
                    {
                        "name": "SEQ_SCAN",
                        "children": [],
                        "extra_info": {
                            "Table": "demo.main.orgs",
                            "Type": "Sequential Scan",
                            "Projections": ["id", "name"],
                            "Estimated Cardinality": "10"
                        }
                    }
                ],
                "extra_info": {
                    "Join Type": "INNER",
                    "Conditions": "org_id = id",
                    "Estimated Cardinality": "181"
                }
            }
        ],
        "extra_info": {
            "Top": "5",
            "Order By": "u.\"name\" ASC"
        }
    }
]
]=]

-- EXPLAIN (ANALYZE, FORMAT JSON) of the same query: bare JSON (no banner), a
-- query-level profile wrapping the EXPLAIN_ANALYZE operator above the real
-- root. cpu_time is cumulative seconds; operator_cardinality is the actual.
local ANALYZE = [=[
{
    "query_name": "EXPLAIN (ANALYZE, FORMAT JSON) SELECT ...",
    "latency": 0.010573342,
    "cpu_time": 0.000307911,
    "rows_returned": 0,
    "extra_info": {},
    "children": [
        {
            "operator_type": "EXPLAIN_ANALYZE",
            "operator_name": "EXPLAIN_ANALYZE",
            "operator_timing": 1.8e-7,
            "operator_cardinality": 0,
            "cpu_time": 0.000307911,
            "extra_info": {},
            "children": [
                {
                    "operator_type": "TOP_N",
                    "operator_name": "TOP_N",
                    "operator_timing": 0.000030467,
                    "operator_cardinality": 5,
                    "cpu_time": 0.000307911,
                    "extra_info": { "Top": "5", "Order By": "u.\"name\" ASC" },
                    "children": [
                        {
                            "operator_type": "HASH_JOIN",
                            "operator_name": "HASH_JOIN",
                            "operator_timing": 0.000069881,
                            "operator_cardinality": 499,
                            "cpu_time": 0.000277444,
                            "extra_info": {
                                "Join Type": "INNER",
                                "Conditions": "org_id = id",
                                "Estimated Cardinality": "181"
                            },
                            "children": [
                                {
                                    "operator_type": "TABLE_SCAN",
                                    "operator_name": "SEQ_SCAN",
                                    "operator_timing": 0.000100641,
                                    "operator_cardinality": 499,
                                    "operator_rows_scanned": 1000,
                                    "cpu_time": 0.000100641,
                                    "extra_info": {
                                        "Table": "demo.main.users",
                                        "Type": "Sequential Scan",
                                        "Filters": ["id>500"],
                                        "Estimated Cardinality": "200"
                                    },
                                    "children": []
                                },
                                {
                                    "operator_type": "TABLE_SCAN",
                                    "operator_name": "SEQ_SCAN",
                                    "operator_timing": 0.000106922,
                                    "operator_cardinality": 10,
                                    "cpu_time": 0.000106922,
                                    "extra_info": {
                                        "Table": "demo.main.orgs",
                                        "Estimated Cardinality": "10"
                                    },
                                    "children": []
                                }
                            ]
                        }
                    ]
                }
            ]
        }
    ]
}
]=]

describe('explain plan: decode (duckdb)', function()
  it('strips the box-art banner and normalizes the plain shape', function()
    local parsed, err = plan.decode('duckdb', PLAIN)
    assert.is_nil(err)
    assert.is_false(parsed.analyzed)

    local top = parsed.root
    assert.equals('Top N', top.op)
    assert.same({ { 'Order By', 'u."name" ASC' }, { 'Top', '5' } }, top.exprs)

    local join = top.children[1]
    assert.equals('Hash Join', join.op) -- INNER stays bare, like postgres
    assert.equals(181, join.plan_rows) -- string estimate -> number
    assert.same({ 'Conditions', 'org_id = id' }, join.exprs[1])

    local users, orgs = join.children[1], join.children[2]
    assert.equals('Seq Scan', users.op)
    assert.equals('demo.main.users', users.relation)
    assert.equals(200, users.plan_rows)
    -- Filters is an array: joined for display.
    assert.same({ 'Filters', 'id>500, optional: Dynamic Filter (name)' }, users.exprs[1])
    assert.equals('demo.main.orgs', orgs.relation)
    -- The detail payload flattens name + extra_info; Projections stay there.
    assert.equals('SEQ_SCAN', users.raw.name)
    assert.same({ 'org_id', 'name' }, users.raw.Projections)

    -- No costs and no timings exist in this shape: nothing derived.
    assert.is_nil(top.total_cost)
    assert.is_nil(top.frac)
  end)

  it('normalizes the analyze profile through the EXPLAIN_ANALYZE wrapper', function()
    local parsed, err = plan.decode('duckdb', ANALYZE)
    assert.is_nil(err)
    assert.is_true(parsed.analyzed)
    assert.is_true(math.abs(parsed.execution_ms - 10.573342) < 1e-9)

    local top = parsed.root
    assert.equals('Top N', top.op) -- the EXPLAIN_ANALYZE wrapper is unwrapped
    assert.equals(5, top.actual_rows)
    -- cpu_time (seconds, cumulative) -> actual_time_ms; exclusive is derived.
    assert.is_true(math.abs(top.actual_time_ms - 0.307911) < 1e-9)
    assert.is_true(math.abs(top.exclusive_ms - (0.307911 - 0.277444)) < 1e-9)

    local join = top.children[1]
    local users = join.children[1]
    assert.equals('Seq Scan', users.op) -- operator_name beats TABLE_SCAN
    assert.equals(499, users.actual_rows)
    assert.equals(200, users.plan_rows)
    assert.is_true(math.abs(users.skew - 499 / 200) < 1e-9)
    -- operator_timing (the node's own time) stays visible in the detail.
    assert.is_true(math.abs(users.raw.operator_timing - 0.000100641) < 1e-18)

    -- frac heats against the root's cumulative time.
    assert.is_true(math.abs(top.frac - top.exclusive_ms / top.total_ms) < 1e-9)
  end)

  it('folds a non-inner join type into the operation name', function()
    local parsed = plan.decode(
      'duckdb',
      vim.json.encode({
        { name = 'HASH_JOIN', children = {}, extra_info = { ['Join Type'] = 'RIGHT_SEMI' } },
      })
    )
    assert.equals('Hash Right Semi Join', parsed.root.op)
  end)

  it("surfaces the profiler's result:error wart instead of an empty tree", function()
    local parsed, err = plan.decode('duckdb', '{ "result": "error" }')
    assert.is_nil(parsed)
    assert.is_truthy(err and err:match('duckdb produced no JSON plan'))
  end)

  it('rejects JSON that is not shaped like a plan', function()
    local parsed, err = plan.decode('duckdb', '{ "unrelated": true }')
    assert.is_nil(parsed)
    assert.is_truthy(err and err:match('no physical plan node'))
  end)
end)
