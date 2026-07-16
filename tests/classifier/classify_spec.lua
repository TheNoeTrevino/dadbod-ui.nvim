-- The classifier's adapter-agnostic contract (dadbod-ui.classifier): the
-- Classification struct shape, the dangerous-implies-changing invariant,
-- alias/enum resolution, and -- the easiest criterion to silently get wrong --
-- that non-SQL and unknown adapters answer "cannot tell" (nil), never a guess.
-- Per-dialect behavior lives in tests/classifier/<adapter>/*_spec.lua.

local classifier = require('dadbod-ui.classifier')
local adapters = require('dadbod-ui.adapters')

describe('classifier: classify contract', function()
  it('returns all four booleans of the Classification struct', function()
    local got = classifier.classify({ adapter = 'postgres', sql = 'SELECT 1' })
    assert.same({
      is_changing = false,
      is_dangerous = false,
      is_plain_select = true,
      is_paginated = false,
    }, got)
  end)

  it('answers nil for mongodb -- not SQL, so it says so instead of guessing', function()
    assert.is_nil(classifier.classify({ adapter = 'mongodb', sql = 'db.users.drop()' }))
  end)

  it('answers nil for an unknown adapter', function()
    assert.is_nil(classifier.classify({ adapter = 'no_such_db', sql = 'DROP TABLE t' }))
  end)

  it('answers nil for a custom adapter that declares no statement patterns', function()
    adapters.register({ name = 'classfake' })
    assert.is_nil(classifier.classify({ adapter = 'classfake', sql = 'DROP TABLE t' }))
    adapters.unregister('classfake')
  end)

  it('classifies a custom adapter that declares patterns, extensions included', function()
    adapters.register({ name = 'classfake', statements = { changing = { 'zap' }, dangerous = { 'zap' } } })
    local got = classifier.classify({ adapter = 'classfake', sql = 'ZAP EVERYTHING' })
    assert.is_true(got.is_changing)
    assert.is_true(got.is_dangerous)
    adapters.unregister('classfake')
  end)

  it('resolves adapter aliases exactly like the registry', function()
    local sql = 'DELETE FROM t'
    assert.same(
      classifier.classify({ adapter = 'postgres', sql = sql }),
      classifier.classify({ adapter = 'postgresql', sql = sql })
    )
  end)

  it('accepts the adapters.Type enum as the adapter field', function()
    local got = classifier.classify({ adapter = adapters.Type.sqlite, sql = 'DROP TABLE t' })
    assert.is_true(got.is_dangerous)
  end)

  it('every built-in SQL adapter is classifiable; only mongodb is not', function()
    for name in pairs(adapters.Type) do
      local got = classifier.classify({ adapter = name, sql = 'SELECT 1' })
      if name == 'mongodb' then
        assert.is_nil(got)
      else
        assert.is_not_nil(got, name .. ' should be classifiable')
      end
    end
  end)

  it('holds the dangerous-implies-changing invariant', function()
    for _, sql in ipairs({
      'DROP TABLE t',
      'TRUNCATE TABLE t',
      'UPDATE t SET a = 1',
      'DELETE FROM t',
    }) do
      local got = classifier.classify({ adapter = 'postgres', sql = sql })
      assert.is_true(got.is_dangerous, sql)
      assert.is_true(got.is_changing, 'dangerous must imply changing: ' .. sql)
    end
  end)

  it('classifies empty / blank input as nothing at all', function()
    assert.same({
      is_changing = false,
      is_dangerous = false,
      is_plain_select = false,
      is_paginated = false,
    }, classifier.classify({ adapter = 'postgres', sql = '  \n ' }))
  end)
end)

describe('classifier: classify_sql (the generic-SQL fallback)', function()
  it('classifies without any adapter, on the shared core alone', function()
    assert.is_true(classifier.classify_sql('DROP TABLE t').is_dangerous)
    assert.is_true(classifier.classify_sql('SELECT * FROM t').is_plain_select)
  end)

  it('applies caller-supplied dialect patterns', function()
    local got = classifier.classify_sql('PURGE RECYCLEBIN', { changing = { 'purge' }, dangerous = { 'purge' } })
    assert.is_true(got.is_changing)
    assert.is_true(got.is_dangerous)
    -- and without the patterns the core alone does not flag it
    assert.is_false(classifier.classify_sql('PURGE RECYCLEBIN').is_changing)
  end)
end)
