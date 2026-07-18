local icons = require('dadbod-ui.icons')
local config = require('dadbod-ui.config')

describe('icons', function()
  it('provides the plain unicode defaults', function()
    local i = icons.resolve(config.resolve())
    assert.equals('▾', i.expanded.db)
    assert.equals('▸', i.collapsed.db)
    assert.equals('*', i.saved_query)
    assert.equals('✓', i.connection_ok)
  end)

  it('uses nerd-font glyphs when enabled', function()
    local i = icons.resolve(config.resolve({ use_nerd_fonts = true }))
    assert.is_truthy(i.expanded.db:find('󰆼'))
    assert.is_truthy(i.expanded.db:find('▾')) -- still carries the toggle
  end)

  it('falls back the group icon to the db icon', function()
    local i = icons.resolve(config.resolve())
    assert.equals(i.expanded.db, i.expanded.group)
    assert.equals(i.collapsed.db, i.collapsed.group)
  end)

  it('applies a per-type override table', function()
    local i = icons.resolve(config.resolve({ icons = { expanded = { db = 'X' } } }))
    assert.equals('X', i.expanded.db)
    assert.equals('▾', i.expanded.tables) -- untouched
  end)

  it('applies a string override to every toggle type', function()
    local i = icons.resolve(config.resolve({ icons = { expanded = '-', collapsed = '+' } }))
    assert.equals('-', i.expanded.db)
    assert.equals('-', i.expanded.tables)
    assert.equals('+', i.collapsed.schema)
  end)

  it('overrides top-level icons', function()
    local i = icons.resolve(config.resolve({ icons = { saved_query = '★' } }))
    assert.equals('★', i.saved_query)
  end)
end)
