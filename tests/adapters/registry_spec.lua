-- Specs for the adapter registry (dadbod-ui.adapters): alias resolution,
-- capability enumeration, and end-to-end custom-adapter registration -- one
-- registered spec must drive every capability module (schemas, table_helpers,
-- explain, paginator, export_adapters) with no other wiring.

local adapters = require('dadbod-ui.adapters')

describe('adapters: registry lookup', function()
  it('resolves canonical names and aliases to the same spec', function()
    assert.are.equal(adapters.get('postgres'), adapters.get('postgresql'))
    assert.are.equal(adapters.get('sqlite'), adapters.get('sqlite3'))
    assert.equals('postgres', adapters.canonical('postgresql'))
    assert.equals('sqlite', adapters.canonical('sqlite3'))
  end)

  it('mariadb is its own adapter deriving from mysql', function()
    local mariadb = adapters.get('mariadb')
    local mysql = adapters.get('mysql')
    assert.is_not.equal(mysql, mariadb)
    assert.equals('mariadb', mariadb.name)
    -- shares mysql's wire behavior...
    assert.are.equal(mysql.schema, mariadb.schema)
    assert.are.equal(mysql.table_helpers, mariadb.table_helpers)
    -- ...but spells its executing EXPLAIN form differently
    assert.equals('ANALYZE {sql}', mariadb.explain.analyze)
  end)

  it('returns nil for unknown schemes', function()
    assert.is_nil(adapters.get('nosuchdb'))
    assert.is_nil(adapters.canonical('nosuchdb'))
    assert.is_nil(adapters.get(nil))
  end)

  it('Type enumerates exactly the built-in adapters, values equal to keys', function()
    for key, value in pairs(adapters.Type) do
      assert.equals(key, value)
      -- every enum value is a registered, resolvable canonical name
      local spec = adapters.get(value)
      assert.is_not_nil(spec, value .. ' is in the enum but not registered')
      assert.equals(value, spec.name)
    end
    -- and nothing built-in is missing from the enum
    for _, name in ipairs(adapters.names()) do
      assert.equals(name, adapters.Type[name], name .. ' is registered but missing from the enum')
    end
  end)

  it('enumerates names, optionally filtered by capability', function()
    local all = adapters.names()
    assert.is_true(vim.tbl_contains(all, 'postgres'))
    assert.is_true(vim.tbl_contains(all, 'mongodb'))
    -- aliases are not enumerated
    assert.is_false(vim.tbl_contains(all, 'postgresql'))
    local exportable = adapters.names('export')
    assert.is_true(vim.tbl_contains(exportable, 'postgres'))
    assert.is_true(vim.tbl_contains(exportable, 'mariadb'))
    -- sqlserver carries no export capability
    assert.is_false(vim.tbl_contains(exportable, 'sqlserver'))
  end)
end)

describe('adapters: custom registration drives every capability', function()
  -- One fake adapter under a scheme no other spec uses. The registry is
  -- process-global, so unregister it after every case -- a leaked fake would
  -- distort other specs' capability enumerations (e.g. explain's supported list).
  local spec
  before_each(function()
    spec = adapters.register({
      name = 'duckfake',
      aliases = { 'duckfake2' },
      schema = function()
        return { schemes_query = 'SELECT s', schemes_tables_query = 'SELECT s, t', quote = true }
      end,
      table_helpers = { List = 'SELECT * FROM "{table}"', Peek = 'SELECT 1' },
      explain = { plain = 'EXPLAIN {sql}' },
      pagination = 'limit_offset',
      export = { stdin = true, extract = { '--csv' }, native = {} },
      normalize_tables = function(raw)
        return vim.tbl_map(string.upper, raw)
      end,
    })
  end)
  after_each(function()
    adapters.unregister('duckfake')
    adapters.unregister('duckfake_api')
  end)

  it('registers under the canonical name and every alias, and unregisters both', function()
    assert.are.equal(spec, adapters.get('duckfake'))
    assert.are.equal(spec, adapters.get('duckfake2'))
    assert.equals('duckfake', adapters.canonical('duckfake2'))
    assert.is_true(adapters.unregister('duckfake'))
    assert.is_nil(adapters.get('duckfake'))
    assert.is_nil(adapters.get('duckfake2'))
    assert.is_false(adapters.unregister('duckfake'))
  end)

  it('schemas.get builds the introspection metadata', function()
    local schemas = require('dadbod-ui.schemas')
    local info = schemas.get('duckfake2')
    assert.equals('SELECT s', info.schemes_query)
    assert.is_true(schemas.supports_schemes(info, { scheme = 'duckfake', path = '/db' }))
    -- normalize_tables routes through the spec
    assert.same({ 'A', 'B' }, schemas.normalize_table_list('duckfake', { 'a', 'b' }))
  end)

  it('table_helpers.get merges user overrides across canonical + alias names', function()
    local helpers = require('dadbod-ui.table_helpers')
    local got = helpers.get('duckfake2', {
      query = { default_query = 'x' },
      -- alias-keyed override applies; exact-scheme override wins on conflict
      table_helpers = { duckfake = { Peek = 'SELECT 2', Extra = 'SELECT 3' }, duckfake2 = { Peek = 'SELECT 4' } },
    })
    assert.equals('SELECT 4', got.Peek)
    assert.equals('SELECT 3', got.Extra)
    assert.equals('SELECT * FROM "{table}"', got.List)
  end)

  it('explain and paginator pick the adapter up', function()
    local explain = require('dadbod-ui.explain')
    assert.is_true(explain.supports('duckfake2'))
    assert.equals('EXPLAIN select 1', explain.wrap('duckfake', 'select 1'))
    local paginator = require('dadbod-ui.paginator')
    assert.equals('select 1 LIMIT 10 OFFSET 0', paginator.paginate('duckfake2', 'select 1', 1, 10))
  end)

  it('export_adapters reads the export flags', function()
    local export_adapters = require('dadbod-ui.export_adapters')
    assert.is_true(export_adapters.supports('duckfake'))
    assert.is_true(export_adapters.uses_stdin('duckfake2'))
    assert.same({ '--csv' }, export_adapters.extract_args('duckfake'))
  end)

  it('is exposed through the api facade', function()
    local registered = require('dadbod-ui.api').register_adapter({ name = 'duckfake_api' })
    assert.are.equal(registered, adapters.get('duckfake_api'))
  end)
end)
