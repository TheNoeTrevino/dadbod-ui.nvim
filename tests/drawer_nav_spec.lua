local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')

-- array form keeps a deterministic order
local function make_drawer()
  local cfg = config.resolve({ save_location = '/tmp/dbui_nav', drawer = { show_help = false } })
  local instance = state.new(cfg):populate({
    env = {},
    g_dbs = {
      { name = 'a', url = 'postgres://h/a' },
      { name = 'b', url = 'postgres://h/b' },
      { name = 'c', url = 'postgres://h/c' },
    },
    file_entries = {},
  })
  local d = drawer_mod.new(instance)
  -- Keep navigation specs offline: expansion would otherwise try to connect.
  -- The expand path connects via `async_connector`; return an empty conn so no
  -- real probe is spawned (state.is_connected treats '' as not connected).
  d.connector = function()
    return ''
  end
  d.async_connector = function(_, on_result)
    vim.schedule(function()
      on_result(true, '')
    end)
  end
  return d
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

  it("next skips over a node's children", function()
    d:set_cursor(1)
    d:toggle_line() -- expand 'a'; line 2 becomes its New query child
    d:set_cursor(1)
    d:goto_sibling('next')
    local node = d.content[cursor_line(d)]
    assert.equals('b', node.label) -- landed on the next db, not its child
    assert.equals(0, node.level)
  end)

  it('last stops at the final same-level sibling when a separator ends the scan', function()
    -- A level-1 sibling (Buffers) followed by a deeper child (buf), then a
    -- top-level separator: `last` must land on Buffers, not the deeper `buf`.
    d.content = {
      { level = 0, label = 'a', type = 'db', action = 'toggle' },
      { level = 1, label = 'New query', type = 'query', action = 'open' },
      { level = 1, label = 'Buffers', type = 'buffers', action = 'toggle' },
      { level = 2, label = 'buf', type = 'buffer', action = 'open' },
      { level = 0, label = '', type = 'help', action = 'noaction' },
      { level = 0, label = 'Query results', type = 'dbout_list', action = 'call_method' },
    }
    vim.bo[d.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(d.bufnr, 0, -1, false, {
      'a',
      'New query',
      'Buffers',
      'buf',
      '',
      'Query results',
    })
    vim.bo[d.bufnr].modifiable = false
    d:set_cursor(2) -- on New query (level 1)
    d:goto_sibling('last')
    assert.equals(3, cursor_line(d)) -- Buffers, the last level-1 sibling
    assert.equals('Buffers', d.content[cursor_line(d)].label)
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

  it('goto parent is a no-op on a top-level node (never jumps to line 1)', function()
    d:set_cursor(2) -- db 'b', a top-level (level 0) node that is not line 1
    d:goto_node('parent')
    assert.equals(2, cursor_line(d)) -- stayed put, did not clamp onto line 1
    assert.equals('b', d.content[cursor_line(d)].label)
  end)
end)
