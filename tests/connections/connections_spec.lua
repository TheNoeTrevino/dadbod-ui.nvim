local connections = require('dadbod-ui.connections')
local config = require('dadbod-ui.config')

local cfg = config.resolve()

describe('connections: key_name', function()
  it('namespaces by group when present', function()
    assert.equals('postgres_file', connections.key_name('postgres', 'file', ''))
    assert.equals('postgres_file', connections.key_name('postgres', 'file', nil))
    assert.equals('Local_postgres_file', connections.key_name('postgres', 'file', 'Local'))
  end)
end)

describe('connections: from_global', function()
  it('reads g:db (single), deriving name from the url tail', function()
    local r = connections.from_global('postgres://localhost/shop', nil)
    assert.equals(1, #r)
    assert.equals('shop', r[1].name)
    assert.equals('g:dbs', r[1].source)
  end)

  it('reads g:dbs dict form', function()
    local r = connections.from_global(nil, { dev = 'postgres://localhost/dev' })
    assert.equals(1, #r)
    assert.equals('dev', r[1].name)
    assert.equals('g:dbs', r[1].source)
  end)

  it('reads g:dbs array form with groups', function()
    local r = connections.from_global(nil, {
      { name = 'pg', url = 'postgres://localhost/a', group = 'Local' },
      { name = 'pg', url = 'postgres://remote/a', group = 'Remote' },
    })
    assert.equals(2, #r)
    assert.equals('Local', r[1].group)
    assert.equals('Local_pg_g:dbs', r[1].key_name)
    assert.equals('Remote_pg_g:dbs', r[2].key_name)
  end)

  it('resolves funcref urls', function()
    local r = connections.from_global(function()
      return 'postgres://localhost/fn'
    end, nil)
    assert.equals('fn', r[1].name)
  end)
end)

describe('connections: from_env', function()
  it('uses DBUI_URL + DBUI_NAME', function()
    local r = connections.from_env({ DBUI_URL = 'postgres://h/db', DBUI_NAME = 'prod' }, cfg)
    assert.equals('prod', r[1].name)
    assert.equals('env', r[1].source)
  end)

  it('falls back to the url tail when no name is given', function()
    local r = connections.from_env({ DBUI_URL = 'postgres://h/inventory' }, cfg)
    assert.equals('inventory', r[1].name)
  end)

  it('respects custom env variable names', function()
    local custom = config.resolve({ env_variable_url = 'MY_URL', env_variable_name = 'MY_NAME' })
    local r = connections.from_env({ MY_URL = 'postgres://h/db', MY_NAME = 'c' }, custom)
    assert.equals('c', r[1].name)
  end)

  it('returns nothing without a url', function()
    assert.same({}, connections.from_env({}, cfg))
  end)
end)

describe('connections: from_dotenv', function()
  it('matches the prefix and lowercases the stripped name', function()
    local r = connections.from_dotenv({ DB_UI_PROD = 'postgres://h/p', OTHER = 'x' }, cfg)
    assert.equals(1, #r)
    assert.equals('prod', r[1].name)
    assert.equals('dotenv', r[1].source)
  end)

  it('respects a custom prefix', function()
    local custom = config.resolve({ dotenv_variable_prefix = 'PG_' })
    local r = connections.from_dotenv({ PG_MAIN = 'postgres://h/m' }, custom)
    assert.equals('main', r[1].name)
  end)

  it('anchors the prefix to the start (ignores a mid-name match)', function()
    -- XDG_DB_UI_CACHE contains DB_UI_ but not at the start, so it is not a conn.
    local r = connections.from_dotenv({ XDG_DB_UI_CACHE = 'postgres://h/c', DB_UI_PROD = 'postgres://h/p' }, cfg)
    assert.equals(1, #r)
    assert.equals('prod', r[1].name)
  end)

  it('strips only the single leading prefix', function()
    -- A later occurrence of the prefix inside the name is left intact.
    local r = connections.from_dotenv({ DB_UI_STAGING_DB_UI_X = 'postgres://h/s' }, cfg)
    assert.equals(1, #r)
    assert.equals('staging_db_ui_x', r[1].name)
  end)
end)

describe('connections: from_file', function()
  it('maps json entries including group', function()
    local r = connections.from_file({
      { name = 'a', url = 'postgres://h/a' },
      { name = 'b', url = 'postgres://h/b', group = 'G' },
    })
    assert.equals('a', r[1].name)
    assert.equals('file', r[1].source)
    assert.equals('G', r[2].group)
  end)
end)

describe('connections: dedup', function()
  it('drops duplicate (name, source, group), first wins', function()
    local dups = {}
    local r = connections.dedup({
      { name = 'pg', source = 'env', group = '', key_name = 'pg_env' },
      { name = 'pg', source = 'env', group = '', key_name = 'pg_env' },
    }, function(name, source)
      dups[#dups + 1] = name .. ':' .. source
    end)
    assert.equals(1, #r)
    assert.same({ 'pg:env' }, dups)
  end)

  it('keeps same name across groups and sources', function()
    local r = connections.dedup({
      { name = 'pg', source = 'file', group = 'A' },
      { name = 'pg', source = 'file', group = 'B' },
      { name = 'pg', source = 'env', group = '' },
    })
    assert.equals(3, #r)
  end)
end)

describe('connections: connections_path / read_file', function()
  it('builds the json path under the save location', function()
    local p = connections.connections_path('/tmp/dbui')
    assert.equals('/tmp/dbui/connections.json', p)
    assert.is_nil(connections.connections_path(''))
  end)

  it('reads a json array, tolerates missing/corrupt files', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local path = dir .. '/connections.json'
    assert.same({}, connections.read_file(path)) -- missing
    vim.fn.writefile({ '[{"name":"a","url":"postgres://h/a"}]' }, path)
    assert.equals('a', connections.read_file(path)[1].name)
    vim.fn.writefile({ '{}' }, path) -- object, not array
    assert.same({}, connections.read_file(path))
    vim.fn.writefile({ 'not json' }, path)
    assert.same({}, connections.read_file(path))
    vim.fn.delete(dir, 'rf')
  end)
end)

describe('connections: discover', function()
  it('merges sources in precedence order with dedup', function()
    local list = connections.discover(cfg, {
      env = { DB_UI_DEV = 'postgres://h/dev', DBUI_URL = 'postgres://h/main' },
      g_db = nil,
      g_dbs = { staging = 'postgres://h/staging' },
      file_entries = { { name = 'prod', url = 'postgres://h/prod' } },
    })
    local by_source = {}
    for _, r in ipairs(list) do
      by_source[r.source] = (by_source[r.source] or 0) + 1
    end
    assert.equals(1, by_source['dotenv'])
    assert.equals(1, by_source['env'])
    assert.equals(1, by_source['g:dbs'])
    assert.equals(1, by_source['file'])
  end)

  it('drops a duplicate across the merged sources', function()
    local list = connections.discover(cfg, {
      env = {},
      g_dbs = { dup = 'postgres://h/1' },
      file_entries = { { name = 'dup', url = 'postgres://h/2' } },
    })
    -- different sources (g:dbs vs file) => both kept
    assert.equals(2, #list)
  end)
end)
