-- Specs for dadbod-ui.table_helpers: the per-adapter helper templates (data
-- only in M6) and the merge/override rules ported from vim-dadbod-ui.

local table_helpers = require('dadbod-ui.table_helpers')
local config = require('dadbod-ui.config')

describe('table_helpers: get', function()
  it('returns the postgres helpers under both scheme names', function()
    local pg = table_helpers.get('postgresql', config.resolve())
    assert.is_string(pg.List)
    assert.is_string(pg.Columns)
    assert.is_string(pg['Foreign Keys'])
    assert.same(pg, table_helpers.get('postgres', config.resolve()))
  end)

  it("uses the configured default query for sqlite's List", function()
    local cfg = config.resolve({ default_query = 'SELECT 42;' })
    local sqlite = table_helpers.get('sqlite', cfg)
    assert.equals('SELECT 42;', sqlite.List)
    assert.is_truthy(sqlite.Columns:match('pragma_table_info'))
    assert.same(table_helpers.get('sqlite', cfg), table_helpers.get('sqlite3', cfg))
  end)

  it('falls back to a single empty List for an unknown adapter', function()
    assert.same({ List = '' }, table_helpers.get('no_such_adapter', config.resolve()))
  end)

  it('merges user overrides over the adapter defaults', function()
    local cfg = config.resolve({ table_helpers = { postgresql = { Custom = 'select now()' } } })
    assert.equals('select now()', table_helpers.get('postgresql', cfg).Custom)
  end)

  it('applies an override given under the aliased scheme name', function()
    local cfg = config.resolve({ table_helpers = { postgres = { Aliased = 'select 1' } } })
    assert.equals('select 1', table_helpers.get('postgresql', cfg).Aliased)
  end)

  it('drops helpers explicitly set to the empty string', function()
    local cfg = config.resolve({ table_helpers = { sqlite = { Columns = '' } } })
    assert.is_nil(table_helpers.get('sqlite', cfg).Columns)
  end)
end)
