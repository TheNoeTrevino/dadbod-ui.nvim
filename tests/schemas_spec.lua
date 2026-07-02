-- Specs for dadbod-ui.schemas: the per-adapter introspection metadata, the
-- result parsers (ported verbatim from vim-dadbod-ui), schema-support detection,
-- and the command-spec construction used by the concurrent introspection path.

local schemas = require('dadbod-ui.schemas')
local config = require('dadbod-ui.config')

describe('schemas: get', function()
  it('returns metadata for supported adapters and shares the postgres alias', function()
    local pg = schemas.get('postgres')
    local pgsql = schemas.get('postgresql')
    assert.is_string(pg.schemes_query)
    assert.is_string(pg.schemes_tables_query)
    assert.equals('public', pg.default_scheme)
    assert.equals(pg.default_scheme, pgsql.default_scheme)
  end)

  it('returns an empty table for an unknown scheme', function()
    assert.same({}, schemas.get('nosuchdb'))
  end)

  it('returns dbout-only metadata for sqlite (no schema support)', function()
    local s = schemas.get('sqlite')
    assert.is_nil(s.schemes_query) -- still the tables-only path
    assert.is_not_nil(s.foreign_key_query) -- but the FK jump is supported
  end)

  it('honors use_postgres_views when building the tables query', function()
    local with_views = schemas.get('postgres', config.resolve({ use_postgres_views = true }))
    local without_views = schemas.get('postgres', config.resolve({ use_postgres_views = false }))
    assert.is_truthy(with_views.schemes_tables_query:match('pg_matviews'))
    assert.is_nil(without_views.schemes_tables_query:match('pg_matviews'))
  end)
end)

describe('schemas: supports_schemes', function()
  it('is true for an adapter exposing a schemes_query', function()
    local pg = schemas.get('postgres')
    assert.is_true(schemas.supports_schemes(pg, { scheme = 'postgres', path = '/db' }))
  end)

  it('is false when the adapter has no schema support', function()
    assert.is_false(schemas.supports_schemes(schemas.get('sqlite'), { scheme = 'sqlite' }))
  end)

  it('is false for mysql/mariadb when the url names a database in the path', function()
    local my = schemas.get('mysql')
    assert.is_false(schemas.supports_schemes(my, { scheme = 'mysql', path = '/app' }))
    assert.is_true(schemas.supports_schemes(my, { scheme = 'mysql', path = '/' }))
  end)
end)

describe('schemas: result parsers (verbatim port)', function()
  it('parses postgres schema and table output, stripping header and row count', function()
    local pg = schemas.get('postgres')
    local schema_lines = { 'schema_name', 'public', 'information_schema', '(2 rows)' }
    assert.same({ 'public', 'information_schema' }, pg.parse_results(schema_lines, 1))

    local table_lines = {
      'table_schema|table_name',
      'public|users',
      'public|posts',
      '(2 rows)',
    }
    assert.same({ { 'public', 'users' }, { 'public', 'posts' } }, pg.parse_results(table_lines, 2))
  end)

  it('parses mysql tab-separated output, dropping the header row', function()
    local my = schemas.get('mysql')
    local schema_lines = { 'schema_name', 'information_schema', 'app' }
    assert.same({ 'information_schema', 'app' }, my.parse_results(schema_lines, 1))

    local table_lines = { 'table_schema\ttable_name', 'app\tusers', 'app\tposts' }
    assert.same({ { 'app', 'users' }, { 'app', 'posts' } }, my.parse_results(table_lines, 2))
  end)

  it('parses sqlserver pipe output, dropping the trailing two lines', function()
    local ss = schemas.get('sqlserver')
    -- sqlcmd appends a blank line and a "(N rows affected)" line.
    local table_lines = { 'dbo|users', 'dbo|posts', '', '(2 rows affected)' }
    assert.same({ { 'dbo', 'users' }, { 'dbo', 'posts' } }, ss.parse_results(table_lines, 2))
  end)
end)

describe('schemas: command_spec', function()
  it('appends the query as an argument for interactive adapters (postgres)', function()
    local pg = schemas.get('postgres')
    local spec = schemas.command_spec('postgres://localhost/db', pg, pg.schemes_query)
    assert.equals('psql', spec.cmd[1])
    assert.equals(pg.schemes_query, spec.cmd[#spec.cmd])
    assert.is_nil(spec.stdin)
    assert.is_truthy(vim.tbl_contains(spec.cmd, '-c'))
  end)

  it('feeds the query on stdin for stdin adapters (mysql)', function()
    local my = schemas.get('mysql')
    local spec = schemas.command_spec('mysql://localhost/', my, my.schemes_query)
    assert.equals(my.schemes_query, spec.stdin)
    assert.is_false(vim.tbl_contains(spec.cmd, my.schemes_query))
  end)
end)

describe('schemas: normalize_table_list', function()
  it('splits and sorts sqlite space-separated table output', function()
    assert.same({ 'a', 'b', 'c', 'd' }, schemas.normalize_table_list('sqlite', { 'c d', 'a  b' }))
  end)

  it('filters mysql header and warning lines', function()
    local raw = { 'mysql: [Warning] Using a password', 'Tables_in_app', 'users', 'posts' }
    assert.same({ 'users', 'posts' }, schemas.normalize_table_list('mysql', raw))
  end)

  it('does not drop a real table whose name merely contains Tables_in_', function()
    -- regression: an unanchored 'Tables_in_' match dropped any table NAMED that
    -- way too, not just the header line dadbod prepends.
    local raw = { 'Tables_in_app', 'my_Tables_in_archive', 'users' }
    assert.same({ 'my_Tables_in_archive', 'users' }, schemas.normalize_table_list('mysql', raw))
  end)

  it('returns the list unchanged for other adapters', function()
    assert.same({ 'users' }, schemas.normalize_table_list('postgres', { 'users' }))
  end)
end)

describe('schemas: result_lines', function()
  it('splits stdout, strips CRs, and drops a trailing blank line', function()
    local lines = schemas.result_lines({ code = 0, stdout = 'a\r\nb\n' })
    assert.same({ 'a', 'b' }, lines)
  end)

  it('returns an empty list on a non-zero exit', function()
    assert.same({}, schemas.result_lines({ code = 1, stdout = 'ignored' }))
  end)
end)
