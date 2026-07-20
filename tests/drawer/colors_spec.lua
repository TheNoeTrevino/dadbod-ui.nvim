-- Specs for connection/group colors in the drawer (issue #91): the pure
-- highlight ranges (the colored NAME prefix of a db/group label), the content
-- builder stamping effective colors onto nodes (own over group), the dynamic
-- `DadbodUIColor_<rrggbb>` groups, and the paint diff repainting a line whose
-- only change is its color.

local highlights = require('dadbod-ui.highlights')
local painter = require('dadbod-ui.drawer.paint')
local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')
local icons_mod = require('dadbod-ui.icons')

local INDENT = 2
local icons = icons_mod.resolve(config.resolve({ use_nerd_fonts = false }))

-- Reproduce paint's line layout for a node (mirrors tests/core/highlights_spec).
local function line_of(node)
  local indent = string.rep(' ', INDENT * (node.level or 0))
  local sep = node.icon ~= '' and ' ' or ''
  return indent .. node.icon .. sep .. node.label
end

local function hls_of(node)
  return highlights.highlights_for(node, line_of(node), icons)
end

local function by_group(hls, group)
  for _, hl in ipairs(hls) do
    if hl.group == group then
      return hl
    end
  end
  return nil
end

-- A drawer over an instance seeded with injected file entries, connector
-- stubbed offline (mirrors tests/drawer/content_spec.lua's helper).
local function make_drawer(file_entries)
  local cfg = config.resolve({ save_location = '/tmp/dbui_colors', drawer = { show_help = false } })
  local instance = state.new(cfg):populate({ env = {}, g_dbs = {}, file_entries = file_entries })
  local d = drawer_mod.new(instance)
  d.connector = function()
    return ''
  end
  return d
end

describe('drawer colors: highlight ranges', function()
  it('paints exactly the name prefix of a colored db label', function()
    local node =
      { type = 'db', icon = '▸', label = 'orders ' .. icons.connection_ok, color = '#ff0000', color_len = #'orders' }
    local hl = by_group(hls_of(node), 'DadbodUIColor_ff0000')
    assert.is_not_nil(hl)
    -- The name starts right after the icon + separator space.
    local start = #'▸' + 1
    assert.equals(start, hl.col_start)
    assert.equals(start + #'orders', hl.col_end)
    -- The status glyph keeps its own group.
    assert.is_not_nil(by_group(hls_of(node), 'DadbodUIConnectionOk'))
  end)

  it('starts at the first non-space when the node has no icon', function()
    local node = { type = 'db', icon = '', label = 'orders', level = 1, color = '#00ff00', color_len = #'orders' }
    local hl = by_group(hls_of(node), 'DadbodUIColor_00ff00')
    assert.is_not_nil(hl)
    assert.equals(INDENT, hl.col_start)
    assert.equals(INDENT + #'orders', hl.col_end)
  end)

  it('adds no color range when the node carries no color (the default look)', function()
    local hls = hls_of({ type = 'db', icon = '▸', label = 'orders' })
    for _, hl in ipairs(hls) do
      assert.is_nil(hl.group:match('^DadbodUIColor_'))
    end
  end)

  it('colors a group node name but not its (Group) details suffix', function()
    local node =
      { type = 'group', icon = '▸', label = 'prod (Group)', detail = true, color = '#ff8800', color_len = #'prod' }
    local hls = hls_of(node)
    local hl = by_group(hls, 'DadbodUIColor_ff8800')
    assert.is_not_nil(hl)
    assert.equals(#'▸' + 1 + #'prod', hl.col_end)
    -- The suffix still renders dimmed.
    assert.is_not_nil(by_group(hls, 'DadbodUIConnectionSource'))
  end)

  it('defines the dynamic group with the hex as foreground', function()
    highlights.color_group('#ff0000')
    local hl = vim.api.nvim_get_hl(0, { name = 'DadbodUIColor_ff0000' })
    assert.equals(0xff0000, hl.fg)
  end)
end)

describe('drawer colors: content builder', function()
  it('stamps own color over group color on db nodes, group color on the group node', function()
    local d = make_drawer({
      { name = 'orders', url = 'sqlite:/tmp/orders.db', group = 'prod', color = '#ff0000' },
      { name = 'qa', url = 'sqlite:/tmp/qa.db', group = 'prod' },
      { group = 'prod', color = '#aa0000' },
    })
    local nodes = d:build_content()
    local group_node = nodes[1]
    assert.equals('group', group_node.type)
    assert.equals('#aa0000', group_node.color)
    assert.equals(#'prod', group_node.color_len)
    local members = group_node.children
    assert.equals('#ff0000', members[1].color) -- own color wins
    assert.equals(#'orders', members[1].color_len)
    assert.equals('#aa0000', members[2].color) -- inherited from the group
  end)

  it('stamps nothing when no color is set', function()
    local d = make_drawer({ { name = 'plain', url = 'sqlite:/tmp/plain.db' } })
    local nodes = d:build_content()
    assert.is_nil(nodes[1].color)
    assert.is_nil(nodes[1].color_len)
  end)
end)

describe('drawer colors: paint diff', function()
  it('repaints a line whose only change is its color', function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    local node = { type = 'db', icon = '▸', label = 'orders', level = 0, color = '#ff0000', color_len = #'orders' }
    local painted = painter.paint(bufnr, { node }, icons)
    local function color_marks()
      return vim.tbl_filter(function(mark)
        return (mark[4].hl_group or ''):match('^DadbodUIColor_') ~= nil
      end, vim.api.nvim_buf_get_extmarks(bufnr, highlights.NS, 0, -1, { details = true }))
    end
    assert.equals('DadbodUIColor_ff0000', color_marks()[1][4].hl_group)

    -- Same text, new color: the key difference must force a repaint.
    local recolored = vim.tbl_extend('force', {}, node, { color = '#00ff00' })
    painter.paint(bufnr, { recolored }, icons, painted)
    assert.equals('DadbodUIColor_00ff00', color_marks()[1][4].hl_group)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)
