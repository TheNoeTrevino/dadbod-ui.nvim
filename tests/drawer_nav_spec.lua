local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')

-- array form keeps a deterministic order
local function make_drawer()
  local cfg = config.resolve({ save_location = '/tmp/dbui_nav' })
  local instance = state.new(cfg):populate({
    env = {},
    g_dbs = {
      { name = 'a', url = 'postgres://h/a' },
      { name = 'b', url = 'postgres://h/b' },
      { name = 'c', url = 'postgres://h/c' },
    },
    file_entries = {},
  })
  return drawer_mod.new(instance)
end

local function cursor_line(d)
  return vim.api.nvim_win_get_cursor(d.winid)[1]
end

describe('drawer: sibling navigation', function()
  local d
  before_each(function()
    d = make_drawer()
    d:open()
  end)
  after_each(function()
    d:close()
  end)

  it('moves to the next and previous sibling', function()
    d:set_cursor(1)
    d:goto_sibling('next')
    assert.equals(2, cursor_line(d))
    d:goto_sibling('prev')
    assert.equals(1, cursor_line(d))
  end)

  it('jumps to the last and first sibling', function()
    d:set_cursor(1)
    d:goto_sibling('last')
    assert.equals(3, cursor_line(d))
    d:goto_sibling('first')
    assert.equals(1, cursor_line(d))
  end)

  it('next skips over a node\'s children', function()
    d:set_cursor(1)
    d:toggle_line() -- expand 'a'; line 2 becomes its New query child
    d:set_cursor(1)
    d:goto_sibling('next')
    local node = d.content[cursor_line(d)]
    assert.equals('b', node.label) -- landed on the next db, not its child
    assert.equals(0, node.level)
  end)
end)

describe('drawer: node navigation', function()
  local d
  before_each(function()
    d = make_drawer()
    d:open()
  end)
  after_each(function()
    d:close()
  end)

  it('goes from a child to its parent', function()
    d:set_cursor(1)
    d:toggle_line() -- expand 'a'; New query at line 2
    d:set_cursor(2)
    d:goto_node('parent')
    assert.equals(1, cursor_line(d))
  end)

  it('descends into a child, expanding a collapsed node', function()
    d:set_cursor(1)
    d:goto_node('child')
    assert.equals(2, cursor_line(d)) -- expanded, moved onto New query
    assert.equals('  + New query', vim.api.nvim_buf_get_lines(d.bufnr, 1, 2, false)[1])
  end)
end)
