local h = require('helper')

-- Navigation specs stay offline (expansion would otherwise connect). The
-- deferring async_connector returns an empty conn so no real probe is spawned.
-- Array form keeps a deterministic order.
local function make_drawer()
  return h.make_drawer({
    g_dbs = {
      { name = 'a', url = 'postgres://h/a' },
      { name = 'b', url = 'postgres://h/b' },
      { name = 'c', url = 'postgres://h/c' },
    },
    connector = 'offline',
    async_connector = 'defer',
  })
end

local function cursor_line(d)
  return vim.api.nvim_win_get_cursor(d.winid)[1]
end

describe('drawer: sibling navigation', function()
  local d
  before_each(function()
    h.clean_ui()
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

  it('last lands on the final sibling under the same parent, never a deeper child', function()
    -- Expand 'a' and give it an expanded Buffers section holding one buffer:
    -- the buffer node (a grandchild) renders between the Buffers header and
    -- the later sections, but siblings are the PARENT'S children, so `last`
    -- from New query must land on the final section header, not the buffer.
    local ids = require('dadbod-ui.drawer.ids')
    local record = d.instance.dbs_list[1] -- 'a'
    local entry = d.instance.dbs[record.key_name]
    entry.buffers = { '/tmp/dbui_nav/buf.sql' }
    d:set_expanded(ids.db(entry.key_name), true)
    d:set_expanded(ids.section(entry.key_name, 'buffers'), true)
    d:render()
    d:set_cursor(2) -- on New query (first child of 'a')
    d:goto_sibling('last')
    local node = d.content[cursor_line(d)]
    assert.equals('a', node.parent.label) -- still a child of 'a'
    assert.equals('schemas', node.type) -- the last section header
    -- and the deeper buffer node was skipped over, not landed on
    assert.is_not.equals('buffer', node.type)
  end)
end)

describe('drawer: node navigation', function()
  local d
  before_each(function()
    h.clean_ui()
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
