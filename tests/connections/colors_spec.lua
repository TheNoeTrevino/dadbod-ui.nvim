-- Specs for connection/group colors in the connections.json store (issue #91):
-- hex normalization, color-carrying discovery records, group-color rows
-- (`{ group, color }`, no url), the set_connection_color / set_group_color
-- transforms, and color preservation through the existing CRUD transforms.

local connections = require('dadbod-ui.connections')

describe('connections: hex color normalization', function()
  -- The validator is module-private; its accept/reject matrix is observable
  -- through group_colors (a row with an invalid color reads as uncolored).
  local function stored(color)
    return connections.group_colors({ { group = 'g', color = color } }).g
  end

  it('accepts #rrggbb in either case, lowercased', function()
    assert.equals('#ff0000', stored('#ff0000'))
    assert.equals('#ff8800', stored('#FF8800'))
  end)

  it('rejects everything else', function()
    assert.is_nil(stored('ff0000')) -- no hash
    assert.is_nil(stored('#f00')) -- 3-digit
    assert.is_nil(stored('#ff00zz')) -- non-hex
    assert.is_nil(stored('#ff000000')) -- too long
    assert.is_nil(stored('red'))
    assert.is_nil(stored(''))
    assert.is_nil(stored(nil))
    assert.is_nil(stored(0xff0000))
  end)
end)

describe('connections: from_file with colors', function()
  it('carries a valid color onto the record, lowercased', function()
    local records = connections.from_file({ { name = 'prod', url = 'sqlite:/tmp/p.db', color = '#FF0000' } })
    assert.equals('#ff0000', records[1].color)
  end)

  it('drops an invalid color instead of propagating it', function()
    local records = connections.from_file({ { name = 'prod', url = 'sqlite:/tmp/p.db', color = 'red' } })
    assert.is_nil(records[1].color)
  end)

  it('leaves color nil when unset (the default look)', function()
    local records = connections.from_file({ { name = 'dev', url = 'sqlite:/tmp/d.db' } })
    assert.is_nil(records[1].color)
  end)

  it('skips group-color rows: they are store metadata, not connections', function()
    local records = connections.from_file({
      { group = 'prod', color = '#ff0000' },
      { name = 'db', url = 'sqlite:/tmp/db.db', group = 'prod' },
    })
    assert.equals(1, #records)
    assert.equals('db', records[1].name)
  end)
end)

describe('connections: group_colors', function()
  it('maps group rows to lowercase group -> lowercase hex', function()
    local colors = connections.group_colors({
      { group = 'Prod', color = '#FF0000' },
      { name = 'db', url = 'sqlite:/tmp/db.db', group = 'Prod' },
    })
    assert.same({ prod = '#ff0000' }, colors)
  end)

  it('ignores connection entries, malformed rows, and invalid colors', function()
    local colors = connections.group_colors({
      { name = 'db', url = 'sqlite:/tmp/db.db', group = 'prod', color = '#00ff00' }, -- a connection, not a group row
      { name = 'x', group = 'prod', color = '#ff0000' }, -- malformed (name, no url): must not recolor the group
      { group = 'test', color = 'not-a-color' },
      { group = '', color = '#123456' },
    })
    assert.same({}, colors)
  end)
end)

describe('connections: set_connection_color', function()
  local base = {
    { name = 'db', url = 'sqlite:/tmp/a.db', group = 'geekom' },
    { name = 'db', url = 'sqlite:/tmp/a.db', group = 'pi' },
  }

  it('sets the color on the targeted clone only (group-disambiguated)', function()
    local out = connections.set_connection_color(base, 'db', 'sqlite:/tmp/a.db', '#FF0000', 'pi')
    assert.is_nil(out[1].color)
    assert.equals('#ff0000', out[2].color)
    assert.is_nil(base[2].color) -- input untouched
  end)

  it('clears with the empty string', function()
    local colored = { { name = 'db', url = 'sqlite:/tmp/a.db', color = '#ff0000' } }
    local out = connections.set_connection_color(colored, 'db', 'sqlite:/tmp/a.db', '')
    assert.is_nil(out[1].color)
  end)

  it('refuses an invalid color with (nil, err), like the sibling transforms', function()
    local out, err = connections.set_connection_color(base, 'db', 'sqlite:/tmp/a.db', 'red', 'pi')
    assert.is_nil(out)
    assert.is_truthy(err and err:find('hex color'))
  end)

  it('is a (nil, nil) no-op when nothing matches, like move_connection', function()
    local out, err = connections.set_connection_color(base, 'nope', 'sqlite:/tmp/a.db', '#ff0000')
    assert.is_nil(out)
    assert.is_nil(err)
  end)
end)

describe('connections: set_group_color', function()
  it('appends a group row for a new group', function()
    local out =
      connections.set_group_color({ { name = 'db', url = 'sqlite:/tmp/a.db', group = 'prod' } }, 'prod', '#FF0000')
    assert.equals(2, #out)
    assert.equals('prod', out[2].group)
    assert.equals('#ff0000', out[2].color)
    assert.is_nil(out[2].url)
  end)

  it('updates an existing row, matching the group case-insensitively', function()
    local out = connections.set_group_color({ { group = 'Prod', color = '#ff0000' } }, 'prod', '#00ff00')
    assert.equals(1, #out)
    assert.equals('#00ff00', out[1].color)
  end)

  it('clearing removes the row entirely', function()
    local base = { { name = 'db', url = 'sqlite:/tmp/a.db' }, { group = 'prod', color = '#ff0000' } }
    local out = connections.set_group_color(base, 'prod', '')
    assert.equals(1, #out)
    assert.equals('db', out[1].name)
    assert.equals(2, #base) -- input untouched
  end)

  it('clearing a group with no row is a (nil, nil) no-op', function()
    local out, err = connections.set_group_color({ { name = 'db', url = 'sqlite:/tmp/a.db' } }, 'prod', '')
    assert.is_nil(out)
    assert.is_nil(err)
  end)

  it('refuses an invalid color or empty group with (nil, err)', function()
    local base = { { group = 'prod', color = '#ff0000' } }
    local out1, err1 = connections.set_group_color(base, 'prod', 'red')
    assert.is_nil(out1)
    assert.is_truthy(err1 and err1:find('hex color'))
    local out2, err2 = connections.set_group_color(base, '', '#00ff00')
    assert.is_nil(out2)
    assert.is_truthy(err2 and err2:find('group name'))
  end)
end)

describe('connections: colors survive the existing CRUD transforms', function()
  it('rename preserves the entry color', function()
    local base = { { name = 'old', url = 'sqlite:/tmp/a.db', color = '#ff0000' } }
    local out = connections.rename_connection(base, 'old', 'sqlite:/tmp/a.db', 'new', 'sqlite:/tmp/b.db')
    assert.equals('#ff0000', out[1].color)
  end)

  it('duplicate carries the source color onto the clone', function()
    local source = { name = 'prod', url = 'sqlite:/tmp/a.db', color = '#ff0000' }
    local out = connections.duplicate_connection({ source }, source, 'clone', 'sqlite:/tmp/a.db', 'pi')
    assert.equals('#ff0000', out[2].color)
  end)

  it('set_group keeps the entry color', function()
    local base = { { name = 'db', url = 'sqlite:/tmp/a.db', color = '#ff0000' } }
    local out = connections.set_group(base, 'db', 'sqlite:/tmp/a.db', 'prod')
    assert.equals('#ff0000', out[1].color)
    assert.equals('prod', out[1].group)
  end)
end)

describe('connections: CRUD transforms tolerate group-color rows', function()
  local base = {
    { group = 'prod', color = '#ff0000' },
    { name = 'a', url = 'sqlite:/tmp/a.db', group = 'prod' },
    { name = 'b', url = 'sqlite:/tmp/b.db', group = 'prod' },
  }

  it('add_connection matches slots past a group row', function()
    local list, err = connections.add_connection(base, 'c', 'sqlite:/tmp/c.db', 'prod')
    assert.is_nil(err)
    assert.equals(4, #list)
  end)

  it('delete_connection leaves the group row in place', function()
    local out = connections.delete_connection(base, 'a', 'sqlite:/tmp/a.db', 'prod')
    assert.equals(2, #out)
    assert.equals('#ff0000', out[1].color)
    assert.is_nil(out[1].url)
  end)

  it('move_connection reorders connections only, preserving the group row', function()
    local out = connections.move_connection(base, 'b', 'sqlite:/tmp/b.db', 'up', 'prod')
    -- Visual order holds the two connections; the group row is re-appended.
    local names = vim.tbl_map(
      function(e)
        return e.name
      end,
      vim.tbl_filter(function(e)
        return e.url ~= nil
      end, out)
    )
    assert.same({ 'b', 'a' }, names)
    local rows = vim.tbl_filter(function(e)
      return e.url == nil
    end, out)
    assert.equals(1, #rows)
    assert.equals('prod', rows[1].group)
  end)

  it('move_connection at the edge is still a clamped no-op', function()
    local list, err = connections.move_connection(base, 'a', 'sqlite:/tmp/a.db', 'up', 'prod')
    assert.is_nil(list)
    assert.is_nil(err)
  end)
end)
