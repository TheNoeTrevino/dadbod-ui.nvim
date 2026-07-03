-- Specs for dadbod-ui.table_helpers: the per-adapter helper templates (data
-- only in M6) and the merge/override rules for table-helper templates.

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

  it('lets an exact-scheme override win over the aliased-scheme one', function()
    local cfg = config.resolve({
      table_helpers = {
        postgres = { List = 'alias wins?' },
        postgresql = { List = 'exact wins' },
      },
    })
    -- The connection's actual scheme (postgresql) must beat its alias (postgres).
    assert.equals('exact wins', table_helpers.get('postgresql', cfg).List)
    assert.equals('alias wins?', table_helpers.get('postgres', cfg).List)
  end)

  it('drops helpers explicitly set to the empty string', function()
    local cfg = config.resolve({ table_helpers = { sqlite = { Columns = '' } } })
    assert.is_nil(table_helpers.get('sqlite', cfg).Columns)
  end)
end)

describe('table_helpers: ordered_names', function()
  it('puts List first and follows the canonical sequence', function()
    local pg = table_helpers.get('postgresql', config.resolve())
    assert.same(
      { 'List', 'Columns', 'Indexes', 'Primary Keys', 'Foreign Keys', 'References' },
      table_helpers.ordered_names(pg)
    )
  end)

  it('orders the same regardless of the input table layout', function()
    local order = table_helpers.ordered_names({
      References = 'x',
      List = 'x',
      ['Foreign Keys'] = 'x',
      Columns = 'x',
    })
    assert.same({ 'List', 'Columns', 'Foreign Keys', 'References' }, order)
  end)

  it('sorts unknown/adapter-specific helpers alphabetically after the canonical ones', function()
    local order = table_helpers.ordered_names({
      List = 'x',
      Describe = 'x',
      Constraints = 'x',
      Custom = 'x',
    })
    assert.same({ 'List', 'Constraints', 'Custom', 'Describe' }, order)
  end)

  it('honors a custom order param, reordering built-ins', function()
    local order = table_helpers.ordered_names({
      List = 'x',
      Columns = 'x',
      Indexes = 'x',
    }, { 'Columns', 'List', 'Indexes' })
    assert.same({ 'Columns', 'List', 'Indexes' }, order)
  end)

  it('places a user-added helper at its configured position in a custom order', function()
    local order = table_helpers.ordered_names({
      List = 'x',
      Columns = 'x',
      Custom = 'x',
    }, { 'Custom', 'List', 'Columns' })
    assert.same({ 'Custom', 'List', 'Columns' }, order)
  end)

  it('skips a name in the order list that this adapter does not have', function()
    local order = table_helpers.ordered_names({
      List = 'x',
      Columns = 'x',
    }, { 'List', 'Indexes', 'Columns', 'Foreign Keys' })
    assert.same({ 'List', 'Columns' }, order)
  end)

  it('sorts a present helper not named in the order list alphabetically after the ordered ones', function()
    local order = table_helpers.ordered_names({
      List = 'x',
      Columns = 'x',
      Custom = 'x',
      Constraints = 'x',
    }, { 'Columns', 'List' })
    assert.same({ 'Columns', 'List', 'Constraints', 'Custom' }, order)
  end)

  it('falls back to fully alphabetical when order is empty', function()
    local order = table_helpers.ordered_names({
      List = 'x',
      Columns = 'x',
      Indexes = 'x',
    }, {})
    assert.same({ 'Columns', 'Indexes', 'List' }, order)
  end)

  it('falls back to fully alphabetical when order names are all unknown', function()
    local order = table_helpers.ordered_names({
      List = 'x',
      Columns = 'x',
    }, { 'DoesNotExist', 'AlsoMissing' })
    assert.same({ 'Columns', 'List' }, order)
  end)

  it('defaults to the module canonical order when order is not passed', function()
    local pg = table_helpers.get('postgresql', config.resolve())
    assert.same(table_helpers.ordered_names(pg), table_helpers.ordered_names(pg, nil))
  end)

  it('uses the resolved config default table_helpers_order (unchanged behavior)', function()
    local cfg = config.resolve()
    local pg = table_helpers.get('postgresql', cfg)
    assert.same(
      { 'List', 'Columns', 'Indexes', 'Primary Keys', 'Foreign Keys', 'References' },
      table_helpers.ordered_names(pg, cfg.table_helpers_order)
    )
  end)
end)
