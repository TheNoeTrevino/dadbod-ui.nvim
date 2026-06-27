local connections = require('dadbod-ui.connections')

describe('connections: write_file / read_file round-trip', function()
  it('writes and reads back a json array', function()
    local dir = vim.fn.tempname()
    local path = dir .. '/connections.json'
    connections.write_file(path, { { name = 'a', url = 'postgres://h/a' } })
    local back = connections.read_file(path)
    assert.equals('a', back[1].name)
    assert.equals('postgres://h/a', back[1].url)
    vim.fn.delete(dir, 'rf')
  end)
end)

describe('connections: add_connection', function()
  it('appends a new connection', function()
    local list, err = connections.add_connection({}, 'dev', 'postgres://h/dev')
    assert.is_nil(err)
    assert.equals(1, #list)
    assert.equals('dev', list[1].name)
  end)

  it('rejects a duplicate name (case-insensitive)', function()
    local base = { { name = 'Dev', url = 'postgres://h/dev' } }
    local list, err = connections.add_connection(base, 'dev', 'postgres://h/other')
    assert.is_nil(list)
    assert.is_truthy(err)
    assert.equals(1, #base) -- input untouched
  end)
end)

describe('connections: delete_connection', function()
  it('removes the matching connection and keeps the rest', function()
    local base = {
      { name = 'a', url = 'postgres://h/a' },
      { name = 'b', url = 'postgres://h/b' },
    }
    local list = connections.delete_connection(base, 'a', 'postgres://h/a')
    assert.equals(1, #list)
    assert.equals('b', list[1].name)
    assert.equals(2, #base) -- input untouched
  end)

  it('matches on resolved url, not raw string', function()
    local base = { { name = 'a', url = 'postgres://h/a' } }
    -- same connection, name differs in case
    local list = connections.delete_connection(base, 'A', 'postgres://h/a')
    assert.equals(0, #list)
  end)
end)

describe('connections: rename_connection', function()
  it('replaces name and url, preserving group', function()
    local base = { { name = 'old', url = 'postgres://h/old', group = 'G' } }
    local list = connections.rename_connection(base, 'old', 'postgres://h/old', 'new', 'postgres://h/new')
    assert.equals('new', list[1].name)
    assert.equals('postgres://h/new', list[1].url)
    assert.equals('G', list[1].group)
  end)

  it('leaves the list unchanged when nothing matches', function()
    local base = { { name = 'a', url = 'postgres://h/a' } }
    local list = connections.rename_connection(base, 'zzz', 'postgres://h/zzz', 'x', 'postgres://h/x')
    assert.equals('a', list[1].name)
  end)
end)
