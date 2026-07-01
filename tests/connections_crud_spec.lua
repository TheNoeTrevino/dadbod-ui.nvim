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

  it('rejects a duplicate name in the same group (case-insensitive)', function()
    local base = { { name = 'Dev', url = 'postgres://h/dev' } }
    local list, err = connections.add_connection(base, 'dev', 'postgres://h/other')
    assert.is_nil(list)
    assert.is_truthy(err)
    assert.equals(1, #base) -- input untouched
  end)

  it('allows the same name in a different group', function()
    local base = { { name = 'postgres', url = 'postgres://geekom/db', group = 'geekom' } }
    local list, err = connections.add_connection(base, 'postgres', 'postgres://pi/db', 'pi')
    assert.is_nil(err)
    assert.equals(2, #list)
    assert.equals('postgres', list[2].name)
    assert.equals('pi', list[2].group)
  end)

  it('rejects the same name in the same group', function()
    local base = { { name = 'postgres', url = 'postgres://geekom/db', group = 'geekom' } }
    local list, err = connections.add_connection(base, 'postgres', 'postgres://geekom/other', 'geekom')
    assert.is_nil(list)
    assert.is_truthy(err)
  end)

  it('stores no group key when ungrouped', function()
    local list = connections.add_connection({}, 'dev', 'postgres://h/dev')
    assert.is_nil(list[1].group)
  end)
end)

describe('connections: duplicate_connection', function()
  it('appends a copy under the new name and url', function()
    local base = { { name = 'dev', url = 'postgres://h/dev' } }
    local list, err = connections.duplicate_connection(base, 'dev_copy', 'postgres://h/analytics')
    assert.is_nil(err)
    assert.equals(2, #list)
    assert.equals('dev_copy', list[2].name)
    assert.equals('postgres://h/analytics', list[2].url)
    assert.equals(1, #base) -- input untouched
  end)

  it('carries over the source group when provided', function()
    local list = connections.duplicate_connection({}, 'pg2', 'postgres://h/two', 'Servers')
    assert.equals('Servers', list[1].group)
  end)

  it('leaves the copy ungrouped for an empty/nil group', function()
    local list = connections.duplicate_connection({}, 'pg2', 'postgres://h/two', '')
    assert.is_nil(list[1].group)
  end)

  it('rejects a name that already exists in the same group (case-insensitive)', function()
    local base = { { name = 'Dev', url = 'postgres://h/dev' } }
    local list, err = connections.duplicate_connection(base, 'dev', 'postgres://h/other')
    assert.is_nil(list)
    assert.is_truthy(err)
    assert.equals(1, #base)
  end)

  it('clones a same-name connection into a different group', function()
    local base = { { name = 'postgres', url = 'postgres://geekom/db', group = 'geekom' } }
    local list, err = connections.duplicate_connection(base, 'postgres', 'postgres://pi/db', 'pi')
    assert.is_nil(err)
    assert.equals(2, #list)
    assert.equals('postgres', list[2].name)
    assert.equals('pi', list[2].group)
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

  it('allows renaming onto a name that exists only in a different group', function()
    local base = {
      { name = 'postgres', url = 'postgres://geekom/db', group = 'geekom' },
      { name = 'db', url = 'postgres://pi/db', group = 'pi' },
    }
    local list, err = connections.rename_connection(base, 'db', 'postgres://pi/db', 'postgres', 'postgres://pi/db')
    assert.is_nil(err)
    assert.equals('postgres', list[2].name)
    assert.equals('pi', list[2].group) -- still pi; the geekom/postgres is untouched
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

describe('connections: move_connection', function()
  local function names(list)
    return vim.tbl_map(function(c)
      return c.name
    end, list)
  end

  it('swaps an ungrouped connection down with its next ungrouped sibling', function()
    local base = {
      { name = 'a', url = 'postgres://h/a' },
      { name = 'b', url = 'postgres://h/b' },
      { name = 'c', url = 'postgres://h/c' },
    }
    local list, err = connections.move_connection(base, 'a', 'postgres://h/a', 'down')
    assert.is_nil(err)
    assert.same({ 'b', 'a', 'c' }, names(list))
    assert.same({ 'a', 'b', 'c' }, names(base)) -- input untouched
  end)

  it('swaps a connection up with its previous sibling', function()
    local base = {
      { name = 'a', url = 'postgres://h/a' },
      { name = 'b', url = 'postgres://h/b' },
    }
    local list = connections.move_connection(base, 'b', 'postgres://h/b', 'up')
    assert.same({ 'b', 'a' }, names(list))
  end)

  it('clamps: moving the first item up is a no-op', function()
    local base = {
      { name = 'a', url = 'postgres://h/a' },
      { name = 'b', url = 'postgres://h/b' },
    }
    local list, err = connections.move_connection(base, 'a', 'postgres://h/a', 'up')
    assert.is_nil(err)
    assert.same({ 'a', 'b' }, names(list))
  end)

  it('clamps: moving the last item down is a no-op', function()
    local base = {
      { name = 'a', url = 'postgres://h/a' },
      { name = 'b', url = 'postgres://h/b' },
    }
    local list = connections.move_connection(base, 'b', 'postgres://h/b', 'down')
    assert.same({ 'a', 'b' }, names(list))
  end)

  it('moves only among group siblings, skipping over other groups', function()
    -- b (group G) sits between two ungrouped members; moving a down should jump
    -- past b to swap with c, its next ungrouped sibling.
    local base = {
      { name = 'a', url = 'postgres://h/a' },
      { name = 'b', url = 'postgres://h/b', group = 'G' },
      { name = 'c', url = 'postgres://h/c' },
    }
    local list = connections.move_connection(base, 'a', 'postgres://h/a', 'down')
    assert.same({ 'c', 'b', 'a' }, names(list))
    assert.equals('G', list[2].group) -- b untouched
  end)

  it('is a no-op for a connection with no siblings in its group', function()
    local base = {
      { name = 'a', url = 'postgres://h/a', group = 'G' },
      { name = 'b', url = 'postgres://h/b' },
    }
    local list = connections.move_connection(base, 'a', 'postgres://h/a', 'down')
    assert.same({ 'a', 'b' }, names(list))
  end)

  it('leaves the list unchanged when nothing matches', function()
    local base = { { name = 'a', url = 'postgres://h/a' } }
    local list, err = connections.move_connection(base, 'zzz', 'postgres://h/zzz', 'down')
    assert.is_nil(err)
    assert.same({ 'a' }, names(list))
  end)
end)

describe('connections: paste_connection', function()
  local function names(list)
    return vim.tbl_map(function(c)
      return c.name
    end, list)
  end

  it('re-inserts the cut connection immediately after the target', function()
    local base = {
      { name = 'a', url = 'postgres://h/a' },
      { name = 'b', url = 'postgres://h/b' },
      { name = 'c', url = 'postgres://h/c' },
    }
    local list, err = connections.paste_connection(base, 'a', 'postgres://h/a', '', 'b', 'postgres://h/b')
    assert.is_nil(err)
    assert.same({ 'b', 'a', 'c' }, names(list))
    assert.same({ 'a', 'b', 'c' }, names(base)) -- input untouched
  end)

  it('adopts the target group when pasting between groups', function()
    local base = {
      { name = 'a', url = 'postgres://h/a' },
      { name = 'b', url = 'postgres://h/b', group = 'G' },
    }
    local list = connections.paste_connection(base, 'a', 'postgres://h/a', 'G', 'b', 'postgres://h/b')
    local a = vim.tbl_filter(function(c)
      return c.name == 'a'
    end, list)[1]
    assert.equals('G', a.group)
  end)

  it('appends at the end and adopts the group when no target anchor is given', function()
    local base = {
      { name = 'a', url = 'postgres://h/a' },
      { name = 'b', url = 'postgres://h/b' },
    }
    local list = connections.paste_connection(base, 'a', 'postgres://h/a', 'G')
    assert.same({ 'b', 'a' }, names(list))
    assert.equals('G', list[2].group)
  end)

  it('drops the group key when pasting into ungrouped space', function()
    local base = {
      { name = 'a', url = 'postgres://h/a', group = 'G' },
      { name = 'b', url = 'postgres://h/b' },
    }
    local list = connections.paste_connection(base, 'a', 'postgres://h/a', '', 'b', 'postgres://h/b')
    assert.is_nil(list[2].group)
    assert.same({ 'b', 'a' }, names(list))
  end)

  it('pasting onto itself is a no-op', function()
    local base = {
      { name = 'a', url = 'postgres://h/a' },
      { name = 'b', url = 'postgres://h/b' },
    }
    local list = connections.paste_connection(base, 'a', 'postgres://h/a', '', 'a', 'postgres://h/a')
    assert.same({ 'a', 'b' }, names(list))
  end)

  it('rejects a paste that collides with a same-name connection in the target group', function()
    local base = {
      { name = 'dev', url = 'postgres://h/a', group = 'G' },
      { name = 'dev', url = 'postgres://h/b' },
    }
    local list, err = connections.paste_connection(base, 'dev', 'postgres://h/b', 'G', 'dev', 'postgres://h/a')
    assert.is_nil(list)
    assert.is_truthy(err)
    assert.equals(2, #base) -- input untouched
  end)

  it('leaves the list unchanged when the cut is missing', function()
    local base = { { name = 'a', url = 'postgres://h/a' } }
    local list = connections.paste_connection(base, 'zzz', 'postgres://h/zzz', '', 'a', 'postgres://h/a')
    assert.same({ 'a' }, names(list))
  end)
end)
