-- Specs for the MySQL/MariaDB plan normalizer: the keyed query_block object
-- tree (wrappers + `table` leaves) lands in the same DadbodUI.PlanNode shape
-- postgres does, with both dialects' field spellings read (MySQL string costs
-- in cost_info, MariaDB `rows` + r_* actuals from ANALYZE FORMAT=JSON).

local plan = require('dadbod-ui.explain.plan')

-- MySQL 8.x: SELECT ... FROM orders o JOIN users u ... ORDER BY -- a Sort over
-- a nested-loop join, costs as strings inside cost_info.
local MYSQL = [=[
{
  "query_block": {
    "select_id": 1,
    "cost_info": { "query_cost": "210.40" },
    "ordering_operation": {
      "using_filesort": true,
      "nested_loop": [
        {
          "table": {
            "table_name": "o",
            "access_type": "ALL",
            "rows_examined_per_scan": 1000,
            "filtered": "10.00",
            "cost_info": { "read_cost": "90.25", "eval_cost": "10.00", "prefix_cost": "100.25" },
            "attached_condition": "(`db`.`o`.`status` = 'open')"
          }
        },
        {
          "table": {
            "table_name": "u",
            "access_type": "eq_ref",
            "key": "PRIMARY",
            "rows_examined_per_scan": 1,
            "cost_info": { "prefix_cost": "210.40" },
            "index_condition": "(`db`.`u`.`id` = `db`.`o`.`user_id`)"
          }
        }
      ]
    }
  }
}
]=]

-- MariaDB ANALYZE FORMAT=JSON: r_* actuals, `rows` spelling, block nesting.
local MARIADB = [=[
{
  "query_block": {
    "select_id": 1,
    "r_loops": 1,
    "r_total_time_ms": 12.5,
    "table": {
      "table_name": "people",
      "access_type": "ALL",
      "rows": 500,
      "r_rows": 480,
      "r_loops": 1,
      "r_total_time_ms": 11.9,
      "filtered": 100,
      "attached_condition": "people.age > 30"
    }
  }
}
]=]

describe('explain plan: decode (mysql/mariadb)', function()
  it('normalizes the MySQL wrapper tree with readable operation names', function()
    local parsed, err = plan.decode('mysql', MYSQL)
    assert.is_nil(err)
    assert.is_false(parsed.analyzed) -- MySQL JSON never carries actuals

    local root = parsed.root
    assert.equals('Query', root.op)
    assert.equals(210.40, root.total_cost)
    local sort = root.children[1]
    assert.equals('Sort', sort.op)
    local join = sort.children[1]
    assert.equals('Nested Loop', join.op)
    assert.equals(2, #join.children)

    local scan, lookup = join.children[1], join.children[2]
    assert.equals('Full Table Scan', scan.op)
    assert.equals('o', scan.relation)
    assert.equals(1000, scan.plan_rows)
    assert.equals(100.25, scan.total_cost) -- prefix_cost preferred, tonumber'd
    assert.same({ { 'Filter', "(`db`.`o`.`status` = 'open')" } }, scan.exprs)
    assert.equals('Unique Lookup', lookup.op)
    assert.equals('PRIMARY', lookup.index_name)
    assert.same({ { 'Index Cond', '(`db`.`u`.`id` = `db`.`o`.`user_id`)' } }, lookup.exprs)
  end)

  it('reads MariaDB actuals: analyzed plan with exclusive-time metrics', function()
    local parsed, err = plan.decode('mariadb', MARIADB)
    assert.is_nil(err)
    assert.is_true(parsed.analyzed)
    local root = parsed.root
    local scan = root.children[1]
    assert.equals('people', scan.relation)
    assert.equals(500, scan.plan_rows) -- the `rows` spelling
    assert.equals(480, scan.actual_rows)
    -- r_total_time_ms is total-across-loops: lands as actual_time_ms, loops=1,
    -- so the shared exclusive math holds: root's own time = 12.5 - 11.9.
    assert.equals(11.9, scan.total_ms)
    assert.is_true(math.abs(root.exclusive_ms - 0.6) < 1e-9)
    assert.is_true(scan.frac > 0.9)
  end)

  it('descends MariaDB structural spellings (filesort, block-nl-join)', function()
    -- MariaDB never emits MySQL's *_operation keys; ORDER BY nests the scan
    -- under `filesort`, and a join-buffer join wraps its inner table in
    -- `block-nl-join` INSIDE the nested_loop array.
    local mariadb_sort = [=[
    {"query_block": {"select_id": 1,
      "filesort": {"sort_key": "t.c",
        "temporary_table": {
          "nested_loop": [
            {"table": {"table_name": "t", "access_type": "ALL", "rows": 10, "r_rows": 10, "r_total_time_ms": 3.0}},
            {"block-nl-join": {"table": {"table_name": "u", "access_type": "ALL", "rows": 5},
                               "attached_condition": "u.id = t.u_id"}}
          ]}}}}
    ]=]
    local parsed = assert(plan.decode('mariadb', mariadb_sort))
    local sort = parsed.root.children[1]
    assert.equals('Sort', sort.op)
    local join = sort.children[1].children[1]
    assert.equals('Nested Loop', join.op)
    assert.equals(2, #join.children)
    assert.equals('t', join.children[1].relation)
    local bnl = join.children[2]
    assert.equals('Block Nested Loop', bnl.op)
    assert.equals('u', bnl.children[1].relation)
    assert.is_true(parsed.analyzed)
  end)

  it('keeps subquery items labeled, raw scalars intact', function()
    local subq = [=[
    {"query_block": {"select_id": 1,
      "table": {"table_name": "a", "access_type": "ALL", "rows": 3},
      "select_list_subqueries": [
        {"dependent": true, "cacheable": false,
         "query_block": {"select_id": 2,
           "table": {"table_name": "b", "access_type": "ALL", "rows": 7}}}
      ]}}
    ]=]
    local parsed = assert(plan.decode('mysql', subq))
    local sub
    for _, child in ipairs(parsed.root.children) do
      if child.op == 'Subquery' then
        sub = child
      end
    end
    assert.is_truthy(sub, 'subquery child kept its label')
    assert.equals(true, sub.raw.dependent) -- detail-float info preserved
    assert.equals('b', sub.children[1].children[1].relation)
  end)

  it('never silently truncates: unknown structural keys become children', function()
    local unknown = [=[
    {"query_block": {"select_id": 1,
      "some_future_wrapper": {"table": {"table_name": "z", "access_type": "ALL", "rows": 2}}}}
    ]=]
    local parsed = assert(plan.decode('mysql', unknown))
    local child = parsed.root.children[1]
    assert.equals('Some Future Wrapper', child.op)
    assert.equals('z', child.children[1].relation)
  end)

  it('errors on JSON without a query_block', function()
    local parsed, err = plan.decode('mysql', '{"rows": 1}')
    assert.is_nil(parsed)
    assert.is_truthy(err and err:match('no query_block'))
  end)
end)
