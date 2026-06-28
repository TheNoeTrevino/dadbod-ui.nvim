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

describe('connections: read_file on corrupt content', function()
  it('returns {} and fires on_error for non-array / invalid json', function()
    local dir = vim.fn.tempname()
    local path = dir .. '/connections.json'
    vim.fn.mkdir(dir, 'p')
    vim.fn.writefile({ '{ this is not valid json array' }, path)
    local hit = false
    local list = connections.read_file(path, function()
      hit = true
    end)
    assert.same({}, list)
    assert.is_true(hit)
    vim.fn.delete(dir, 'rf')
  end)

  it('does not fire on_error for a missing file', function()
    local hit = false
    local list = connections.read_file(vim.fn.tempname() .. '/nope.json', function()
      hit = true
    end)
    assert.same({}, list)
    assert.is_false(hit)
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

  it('rejects renaming onto another connection name (case-insensitive)', function()
    local base = {
      { name = 'Geekom', url = 'postgres://h/a' },
      { name = 'Geekom2', url = 'postgres://h/b' },
    }
    local list, err = connections.rename_connection(base, 'Geekom2', 'postgres://h/b', 'geekom', 'postgres://h/b')
    assert.is_nil(list)
    assert.is_truthy(err)
    assert.equals(2, #base) -- input untouched
  end)

  it('allows a rename that keeps its own name (editing only the url)', function()
    local base = { { name = 'a', url = 'postgres://h/a' } }
    local list, err = connections.rename_connection(base, 'a', 'postgres://h/a', 'a', 'postgres://h/new')
    assert.is_nil(err)
    assert.equals('postgres://h/new', list[1].url)
  end)
end)

describe('connections: set_group', function()
  it('assigns a group to a connection', function()
    local base = { { name = 'a', url = 'postgres://h/a' } }
    local list, err = connections.set_group(base, 'a', 'postgres://h/a', 'Local')
    assert.is_nil(err)
    assert.equals('Local', list[1].group)
    assert.is_nil(base[1].group) -- input untouched
  end)

  it('joins an existing group (two connections share the name)', function()
    local base = {
      { name = 'a', url = 'postgres://h/a', group = 'Local' },
      { name = 'b', url = 'postgres://h/b' },
    }
    local list = connections.set_group(base, 'b', 'postgres://h/b', 'Local')
    assert.equals('Local', list[2].group)
  end)

  it('clears the group when given an empty name', function()
    local base = { { name = 'a', url = 'postgres://h/a', group = 'Local' } }
    local list = connections.set_group(base, 'a', 'postgres://h/a', '')
    assert.is_nil(list[1].group)
  end)

  it('rejects grouping onto a same-name connection already in that group', function()
    local base = {
      { name = 'dev', url = 'postgres://h/a', group = 'Local' },
      { name = 'dev', url = 'postgres://h/b' },
    }
    local list, err = connections.set_group(base, 'dev', 'postgres://h/b', 'Local')
    assert.is_nil(list)
    assert.is_truthy(err)
  end)
end)
