-- Specs for the pure drawer highlighting (M10): highlights.highlights_for returns
-- the correct group + byte ranges for each node kind WITHOUT a buffer, mirroring
-- the build_content/paint purity split. Byte ranges are asserted against the same
-- line text paint builds (indent + icon + sep + label).

local highlights = require('dadbod-ui.highlights')
local icons_mod = require('dadbod-ui.icons')
local config = require('dadbod-ui.config')

local INDENT = 2

-- The unicode (non-nerd-font) icon set, so glyph byte widths are predictable.
local icons = icons_mod.resolve(config.resolve({ use_nerd_fonts = false }))

-- Reproduce paint's line layout for a node.
---@param node table
---@return string
local function line_of(node)
  local indent = string.rep(' ', INDENT * (node.level or 0))
  local sep = node.icon ~= '' and ' ' or ''
  return indent .. node.icon .. sep .. node.label
end

---@param node table
---@return table[]
local function hls_of(node)
  return highlights.highlights_for(node, line_of(node), icons)
end

-- The first highlight with `group`, or nil.
local function by_group(hls, group)
  for _, hl in ipairs(hls) do
    if hl.group == group then
      return hl
    end
  end
  return nil
end

describe('highlights.highlights_for', function()
  it('highlights the icon column of a db node as DadbodUIIcon', function()
    local node = { type = 'db', level = 0, icon = icons.collapsed.db, label = 'dev' }
    local hls = hls_of(node)
    local icon = by_group(hls, 'DadbodUIIcon')
    assert.is_not_nil(icon)
    assert.equals(0, icon.col_start)
    assert.equals(#icons.collapsed.db, icon.col_end)
  end)

  it('marks the connection-ok glyph on a connected db', function()
    local label = 'dev ' .. icons.connection_ok
    local node = { type = 'db', level = 0, icon = icons.collapsed.db, label = label }
    local line = line_of(node)
    local hl = by_group(hls_of(node), 'DadbodUIConnectionOk')
    assert.is_not_nil(hl)
    -- range covers exactly the ok glyph
    assert.equals(icons.connection_ok, line:sub(hl.col_start + 1, hl.col_end))
  end)

  it('marks the connection-error glyph on a failed db', function()
    local label = 'dev ' .. icons.connection_error
    local node = { type = 'db', level = 0, icon = icons.collapsed.db, label = label }
    local line = line_of(node)
    local hl = by_group(hls_of(node), 'DadbodUIConnectionError')
    assert.is_not_nil(hl)
    assert.equals(icons.connection_error, line:sub(hl.col_start + 1, hl.col_end))
    assert.is_nil(by_group(hls_of(node), 'DadbodUIConnectionOk'))
  end)

  it('dims the (scheme - source) detail suffix as Comment', function()
    local node = { type = 'db', level = 0, icon = icons.collapsed.db, label = 'dev (postgres - g:dbs)' }
    local line = line_of(node)
    local hl = by_group(hls_of(node), 'DadbodUIConnectionSource')
    assert.is_not_nil(hl)
    assert.equals('(postgres - g:dbs)', line:sub(hl.col_start + 1, hl.col_end))
  end)

  it('highlights a help line and its key token', function()
    local node = { type = 'help', level = 0, icon = '', label = '" o - Open/Toggle selected item' }
    local line = line_of(node)
    local hls = hls_of(node)
    local help = by_group(hls, 'DadbodUIHelp')
    assert.is_not_nil(help)
    assert.equals(0, help.col_start)
    assert.equals(#line, help.col_end)
    local key = by_group(hls, 'DadbodUIHelpKey')
    assert.is_not_nil(key)
    assert.equals('o', line:sub(key.col_start + 1, key.col_end))
  end)

  it('handles a multi-key help token', function()
    local node = { type = 'help', level = 0, icon = '', label = '" <C-j>/<C-k> - Go to last/first sibling' }
    local line = line_of(node)
    local key = by_group(hls_of(node), 'DadbodUIHelpKey')
    assert.is_not_nil(key)
    assert.equals('<C-j>/<C-k>', line:sub(key.col_start + 1, key.col_end))
  end)

  it('does not highlight a non-key help hint line', function()
    local node = { type = 'help', level = 0, icon = '', label = '" Press ? for help' }
    local hls = hls_of(node)
    assert.is_not_nil(by_group(hls, 'DadbodUIHelp'))
    assert.is_nil(by_group(hls, 'DadbodUIHelpKey'))
  end)

  it('uses per-type icon groups for new_query / saved_query / buffers / tables', function()
    local cases = {
      { type = 'query', icon = icons.new_query, group = 'DadbodUINewQuery' },
      { type = 'saved_query', icon = icons.saved_query, group = 'DadbodUISavedQuery' },
      { type = 'buffer', icon = icons.buffers, group = 'DadbodUIBuffers' },
      { type = 'table_helper', icon = icons.tables, group = 'DadbodUITables' },
      { type = 'dbout', icon = icons.tables, group = 'DadbodUITables' },
    }
    for _, c in ipairs(cases) do
      local node = { type = c.type, level = 1, icon = c.icon, label = 'x' }
      local hl = by_group(hls_of(node), c.group)
      assert.is_not_nil(hl, c.type .. ' should map to ' .. c.group)
      assert.equals(INDENT, hl.col_start) -- after the level-1 indent
    end
  end)

  it('produces no highlights for a blank help separator line', function()
    local node = { type = 'help', level = 0, icon = '', label = '' }
    assert.equals(0, #hls_of(node))
  end)
end)

describe('highlights.define', function()
  it('defines the groups with concrete bg-aware connection colors', function()
    highlights.define()
    local ok = vim.api.nvim_get_hl(0, { name = 'DadbodUIConnectionOk' })
    assert.is_not_nil(ok.fg)
    local err = vim.api.nvim_get_hl(0, { name = 'DadbodUIConnectionError' })
    assert.is_not_nil(err.fg)
    -- the link groups default-link to standard groups (overridable)
    local icon = vim.api.nvim_get_hl(0, { name = 'DadbodUIIcon' })
    assert.equals('Directory', icon.link)
  end)
end)
