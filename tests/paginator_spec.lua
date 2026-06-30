-- Specs for dadbod-ui.paginator: the per-adapter LIMIT/OFFSET rewrite and the
-- guard cases (already-paged / non-SELECT / multi-statement / unsupported
-- adapter), modelled on DBeaver's clause-append approach.

local paginator = require('dadbod-ui.paginator')

describe('paginator: supports', function()
  it('reports the supported adapters under raw and canonical names', function()
    for _, scheme in ipairs({
      'postgres',
      'postgresql',
      'sqlite',
      'sqlite3',
      'mysql',
      'mariadb',
      'clickhouse',
      'bigquery',
    }) do
      assert.is_true(paginator.supports(scheme), scheme .. ' should be supported')
    end
  end)

  it('reports sqlserver and oracle as unsupported', function()
    assert.is_false(paginator.supports('sqlserver'))
    assert.is_false(paginator.supports('oracle'))
    assert.is_false(paginator.supports('no_such_adapter'))
  end)
end)

describe('paginator: paginate (LIMIT/OFFSET styles)', function()
  it('appends LIMIT <length> OFFSET <offset> for postgres-style adapters', function()
    for _, scheme in ipairs({ 'postgres', 'postgresql', 'sqlite', 'sqlite3', 'clickhouse', 'bigquery' }) do
      assert.equals('SELECT * FROM t LIMIT 200 OFFSET 0', paginator.paginate(scheme, 'SELECT * FROM t', 1, 200))
      assert.equals('SELECT * FROM t LIMIT 200 OFFSET 400', paginator.paginate(scheme, 'SELECT * FROM t', 3, 200))
    end
  end)

  it('appends the combined LIMIT <offset>, <length> for mysql/mariadb', function()
    assert.equals('SELECT * FROM t LIMIT 0, 50', paginator.paginate('mysql', 'SELECT * FROM t', 1, 50))
    assert.equals('SELECT * FROM t LIMIT 100, 50', paginator.paginate('mariadb', 'SELECT * FROM t', 3, 50))
  end)

  it('computes offset as (page - 1) * page_size', function()
    assert.equals('SELECT 1 LIMIT 10 OFFSET 0', paginator.paginate('postgres', 'SELECT 1', 1, 10))
    assert.equals('SELECT 1 LIMIT 10 OFFSET 10', paginator.paginate('postgres', 'SELECT 1', 2, 10))
    assert.equals('SELECT 1 LIMIT 10 OFFSET 90', paginator.paginate('postgres', 'SELECT 1', 10, 10))
  end)

  it('strips a trailing semicolon (and whitespace) before appending', function()
    assert.equals('SELECT * FROM t LIMIT 200 OFFSET 0', paginator.paginate('postgres', 'SELECT * FROM t;  \n', 1, 200))
  end)

  it('paginates a lowercase / multiline SELECT', function()
    assert.equals('select *\nfrom t LIMIT 200 OFFSET 0', paginator.paginate('postgres', 'select *\nfrom t', 1, 200))
  end)
end)

describe('paginator: paginate (guards return nil)', function()
  it('returns nil for an unsupported adapter', function()
    assert.is_nil(paginator.paginate('sqlserver', 'SELECT * FROM t', 1, 200))
    assert.is_nil(paginator.paginate('oracle', 'SELECT * FROM t', 1, 200))
  end)

  it('returns nil when the query already carries a paging clause', function()
    assert.is_nil(paginator.paginate('postgres', 'SELECT * FROM t LIMIT 10', 1, 200))
    assert.is_nil(paginator.paginate('postgres', 'SELECT * FROM t OFFSET 5', 1, 200))
    assert.is_nil(paginator.paginate('postgres', 'SELECT * FROM t FETCH FIRST 10 ROWS ONLY', 1, 200))
    assert.is_nil(paginator.paginate('mysql', 'select * from t limit 10', 1, 200))
  end)

  it('returns nil for non-SELECT statements', function()
    assert.is_nil(paginator.paginate('postgres', 'UPDATE t SET x = 1', 1, 200))
    assert.is_nil(paginator.paginate('postgres', 'INSERT INTO t VALUES (1)', 1, 200))
    assert.is_nil(paginator.paginate('postgres', 'DELETE FROM t', 1, 200))
    assert.is_nil(paginator.paginate('postgres', 'SELECT * INTO new_t FROM t', 1, 200))
  end)

  it('returns nil for a multi-statement query', function()
    assert.is_nil(paginator.paginate('postgres', 'SELECT * FROM a; SELECT * FROM b', 1, 200))
  end)
end)
