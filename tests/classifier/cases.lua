-- The data-driven driver + dialect-neutral case tables for the per-adapter
-- classifier specs (tests/classifier/<adapter>/*_spec.lua).
--
-- Each case is `{ sql, expect = { field = bool, ... }, label? }` -- `expect`
-- names only the classification fields the case is about. `run` builds one
-- `it` per case and classifies through the real adapter registry, so an
-- adapter's own `statements` extensions (oracle PURGE) apply exactly as they
-- do in production.
--
-- The shared tables below are plain ANSI-ish SQL every dialect accepts; a
-- per-adapter spec runs them AND appends its dialect-specific cases, so the
-- same behavior is proven per adapter (an adapter override that broke the
-- core would fail that adapter's spec, nobody else's).

local classifier = require('dadbod-ui.classifier')

local M = {}

---@param adapter string  canonical adapter name the cases classify under
---@param title string    describe-block suffix ('changing', 'dangerous', ...)
---@param cases { sql: string, expect: table<string, boolean>, label?: string }[]
function M.run(adapter, title, cases)
  describe(('classifier/%s: %s'):format(adapter, title), function()
    for _, case in ipairs(cases) do
      it(case.label or case.sql:gsub('%s+', ' '), function()
        local got = classifier.classify({ adapter = adapter, sql = case.sql })
        assert.is_not_nil(got, adapter .. ' should be classifiable')
        for field, want in pairs(case.expect) do
          assert.equals(want, got[field], ('%s for [%s]'):format(field, case.sql))
        end
      end)
    end
  end)
end

-- is_changing: does the statement mutate anything ---------------------------
M.changing = {
  { sql = 'SELECT * FROM t', expect = { is_changing = false, is_dangerous = false } },
  { sql = 'INSERT INTO t (a) VALUES (1)', expect = { is_changing = true, is_dangerous = false } },
  { sql = 'UPDATE t SET a = 1 WHERE id = 2', expect = { is_changing = true, is_dangerous = false } },
  { sql = 'DELETE FROM t WHERE id = 2', expect = { is_changing = true, is_dangerous = false } },
  { sql = 'CREATE TABLE t (id int)', expect = { is_changing = true, is_dangerous = false } },
  { sql = 'ALTER TABLE t ADD COLUMN b int', expect = { is_changing = true, is_dangerous = false } },
  { sql = 'GRANT SELECT ON t TO reader', expect = { is_changing = true } },
  {
    sql = 'SELECT 1; UPDATE t SET a = 1 WHERE id = 2',
    expect = { is_changing = true },
    label = 'a mutation hiding behind a leading SELECT',
  },
  {
    sql = "SELECT * FROM audit WHERE action = 'delete'",
    expect = { is_changing = false },
    label = 'mutating keyword inside a string literal',
  },
  {
    sql = 'SELECT a -- update this later\nFROM t',
    expect = { is_changing = false },
    label = 'mutating keyword inside a line comment',
  },
  {
    sql = 'SELECT a /* drop me */ FROM t',
    expect = { is_changing = false, is_dangerous = false },
    label = 'mutating keyword inside a block comment',
  },
  {
    sql = 'SELECT updated_at, created_at FROM t',
    expect = { is_changing = false },
    label = 'keyword as a prefix of an identifier does not count',
  },
  {
    sql = 'WITH doomed AS (SELECT id FROM t) DELETE FROM t WHERE id IN (SELECT id FROM doomed)',
    expect = { is_changing = true, is_dangerous = false },
    label = 'CTE-fronted DELETE',
  },
}

-- is_dangerous: DROP/TRUNCATE, or UPDATE/DELETE with no WHERE ---------------
-- (always alongside is_changing = true: dangerous is a subset of changing)
M.dangerous = {
  { sql = 'DROP TABLE t', expect = { is_changing = true, is_dangerous = true } },
  { sql = 'TRUNCATE TABLE t', expect = { is_changing = true, is_dangerous = true } },
  { sql = 'UPDATE t SET a = 1', expect = { is_dangerous = true }, label = 'UPDATE with no WHERE' },
  { sql = 'DELETE FROM t', expect = { is_dangerous = true }, label = 'DELETE with no WHERE' },
  {
    sql = 'UPDATE t\nSET a = 1\nWHERE id = 2',
    expect = { is_dangerous = false },
    label = 'multiline UPDATE with the WHERE on a later line',
  },
  {
    sql = "UPDATE t SET note = 'where credit is due'",
    expect = { is_dangerous = true },
    label = 'a WHERE only inside a string literal does not protect',
  },
  {
    sql = 'DELETE FROM t -- where id = 1',
    expect = { is_dangerous = true },
    label = 'a WHERE only inside a comment does not protect',
  },
  {
    sql = 'DELETE FROM t WHERE 1 = 1',
    expect = { is_dangerous = false },
    label = 'a tautological WHERE still counts -- not ours to judge',
  },
  {
    sql = 'UPDATE t SET a = 1 WHERE id = 1; DELETE FROM u',
    expect = { is_dangerous = true },
    label = 'the WHERE check is per statement, not per query text',
  },
  {
    sql = 'WITH x AS (SELECT 1) DELETE FROM t',
    expect = { is_dangerous = true },
    label = 'CTE-fronted DELETE with no WHERE',
  },
}

-- is_plain_select / is_paginated: two facts, deliberately apart -------------
-- (#97: wrapping `SELECT ... LIMIT 10` in a subquery is fine even though you
-- could not append another LIMIT to it)
M.pagination = {
  { sql = 'SELECT * FROM t', expect = { is_plain_select = true, is_paginated = false } },
  { sql = 'select *\nfrom t', expect = { is_plain_select = true, is_paginated = false } },
  {
    sql = 'SELECT * FROM t LIMIT 10',
    expect = { is_plain_select = true, is_paginated = true },
    label = 'already paged, but still a plain SELECT',
  },
  { sql = 'SELECT * FROM t OFFSET 5', expect = { is_paginated = true } },
  { sql = 'SELECT * FROM t FETCH FIRST 10 ROWS ONLY', expect = { is_paginated = true } },
  { sql = 'SELECT * INTO new_t FROM t', expect = { is_plain_select = false, is_paginated = false } },
  {
    sql = 'SELECT * FROM t FOR UPDATE',
    expect = { is_plain_select = false },
    label = 'a row-locking SELECT is not plain',
  },
  { sql = 'UPDATE t SET a = 1 WHERE id = 1', expect = { is_plain_select = false, is_paginated = false } },
  { sql = 'SELECT * FROM a; SELECT * FROM b', expect = { is_plain_select = false }, label = 'multi-statement' },
  {
    sql = "SELECT * FROM t WHERE note = 'limit 5'",
    expect = { is_plain_select = true, is_paginated = false },
    label = 'paging word inside a string literal does not page',
  },
  {
    sql = 'WITH x AS (SELECT 1) SELECT * FROM x',
    expect = { is_plain_select = false },
    label = 'a CTE SELECT is not (yet) plain -- matches the historical paginator guard',
  },
}

return M
