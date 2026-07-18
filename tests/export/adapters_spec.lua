-- Specs for dadbod-ui.export.adapters: the export capability matrix (§4) +
-- Appendix A argv. Pure data + small accessors, modelled on paginator_spec.

local adapters = require('dadbod-ui.export.adapters')

-- The OS null device the adapter uses to skip sqlite's rc file (matches the module).
local NULLDEV = vim.fn.has('win32') == 1 and 'NUL' or '/dev/null'

describe('export.adapters.supports', function()
  it('supports postgres, mysql/mariadb, sqlite under raw + canonical names', function()
    for _, s in ipairs({ 'postgres', 'postgresql', 'mysql', 'mariadb', 'sqlite', 'sqlite3' }) do
      assert.is_true(adapters.supports(s), s .. ' should be supported')
    end
  end)

  it('reports other adapters as unsupported (v1, DECISION-004)', function()
    for _, s in ipairs({ 'sqlserver', 'oracle', 'bigquery', 'clickhouse', 'nope' }) do
      assert.is_false(adapters.supports(s))
    end
  end)
end)

describe('export.adapters.formats_for', function()
  it('offers every format for a supported adapter', function()
    assert.are.same({ 'csv', 'json', 'markdown', 'html', 'xml', 'sql', 'tsv' }, adapters.formats_for('postgres'))
  end)

  it('returns an empty list for an unsupported adapter', function()
    assert.are.same({}, adapters.formats_for('oracle'))
  end)

  it('returns an independent copy each call', function()
    local a = adapters.formats_for('sqlite')
    table.remove(a)
    assert.are.equal(7, #adapters.formats_for('sqlite'))
  end)
end)

describe('export.adapters.extract_args + uses_stdin (Appendix A)', function()
  it('postgres extracts with --no-psqlrc --csv -c, query as arg', function()
    assert.are.same({ '--no-psqlrc', '--csv', '-c' }, adapters.extract_args('postgres'))
    assert.is_false(adapters.uses_stdin('postgres'))
  end)

  it('sqlite extracts with -init NULLDEV -csv -header, query on stdin (leading-dash safe)', function()
    assert.are.same({ '-init', NULLDEV, '-csv', '-header' }, adapters.extract_args('sqlite3'))
    assert.is_true(adapters.uses_stdin('sqlite')) -- stdin, not a positional arg
  end)

  it('mysql extracts with --batch, query on stdin', function()
    assert.are.same({ '--batch' }, adapters.extract_args('mariadb'))
    assert.is_true(adapters.uses_stdin('mysql'))
  end)

  it('returns nil extract args / false stdin for unsupported', function()
    assert.is_nil(adapters.extract_args('oracle'))
    assert.is_false(adapters.uses_stdin('oracle'))
  end)
end)

describe('export.adapters.native_args + is_native (§4 matrix)', function()
  it('sqlite emits csv/json natively (NOT markdown/html: not reproducible across versions)', function()
    assert.are.same({ '-init', NULLDEV, '-csv', '-header' }, adapters.native_args('sqlite', 'csv'))
    assert.are.same({ '-init', NULLDEV, '-json' }, adapters.native_args('sqlite', 'json'))
    assert.is_nil(adapters.native_args('sqlite', 'markdown')) -- version-dependent numeric alignment
    assert.is_nil(adapters.native_args('sqlite', 'html')) -- T16: use the Lua formatter
    assert.is_nil(adapters.native_args('sqlite', 'xml'))
    assert.is_nil(adapters.native_args('sqlite', 'sql'))
  end)

  it('postgres emits csv + html natively (rc-suppressed), nothing else', function()
    assert.are.same({ '--no-psqlrc', '--csv', '-c' }, adapters.native_args('postgres', 'csv'))
    assert.are.same({ '--no-psqlrc', '-H', '-c' }, adapters.native_args('postgres', 'html'))
    assert.is_nil(adapters.native_args('postgres', 'json'))
    assert.is_nil(adapters.native_args('postgres', 'markdown'))
  end)

  it('mysql emits html/xml natively; TSV is the Lua formatter (uniform NULL handling)', function()
    assert.are.same({ '--html' }, adapters.native_args('mysql', 'html'))
    assert.are.same({ '--xml' }, adapters.native_args('mysql', 'xml'))
    assert.is_nil(adapters.native_args('mysql', 'tsv')) -- dropped: raw \N framing
    assert.is_nil(adapters.native_args('mysql', 'csv'))
    assert.is_nil(adapters.native_args('mysql', 'json'))
  end)

  it('is_native honours prefer_native and the matrix', function()
    assert.is_true(adapters.is_native('sqlite', 'json', true))
    assert.is_false(adapters.is_native('sqlite', 'json', false)) -- prefer_native off
    assert.is_false(adapters.is_native('sqlite', 'xml', true)) -- not native for sqlite
    assert.is_false(adapters.is_native('oracle', 'csv', true)) -- unsupported
  end)
end)
