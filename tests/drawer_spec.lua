local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')

-- Build a drawer over an instance seeded with injected connections.
local function make_drawer(g_dbs, overrides)
  local cfg = config.resolve(vim.tbl_extend('force', { save_location = '/tmp/dbui_drawer' }, overrides or {}))
  local instance = state.new(cfg):populate({ env = {}, g_dbs = g_dbs, file_entries = {} })
  return drawer_mod.new(instance)
end

local function lines(d)
  return vim.api.nvim_buf_get_lines(d.bufnr, 0, -1, false)
end

describe('drawer: window', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('opens a dbui window and reports open state', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    d:open()
    assert.is_true(d:is_open())
    assert.equals('dbui', vim.bo[d.bufnr].filetype)
    assert.equals('nofile', vim.bo[d.bufnr].buftype)
  end)

  it('closes the window', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    d:open()
    d:close()
    assert.is_false(d:is_open())
  end)

  it('toggles open/closed', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    d:toggle()
    assert.is_true(d:is_open())
    d:toggle()
    assert.is_false(d:is_open())
  end)
end)

describe('drawer: render', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('renders connections collapsed with the db icon', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    d:open()
    assert.equals('▸ dev', lines(d)[1])
  end)

  it('expands a connection to show New query, then collapses', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    d:open()
    vim.api.nvim_win_set_cursor(d.winid, { 1, 0 })
    d:toggle_line()
    local l = lines(d)
    assert.equals('▾ dev', l[1])
    assert.equals('  + New query', l[2])
    d:toggle_line()
    assert.equals('▸ dev', lines(d)[1])
    assert.is_nil(lines(d)[2])
  end)
end)

describe('drawer: groups', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('renders a group header with indented members', function()
    d = make_drawer({
      { name = 'pg', url = 'postgres://h/a', group = 'Local' },
    })
    d:open()
    local l = lines(d)
    assert.equals('▾ Local', l[1]) -- expand_groups default true
    assert.equals('  ▸ pg', l[2])
  end)

  it('collapsing a group hides its members', function()
    d = make_drawer({
      { name = 'pg', url = 'postgres://h/a', group = 'Local' },
    })
    d:open()
    vim.api.nvim_win_set_cursor(d.winid, { 1, 0 })
    d:toggle_line()
    local l = lines(d)
    assert.equals('▸ Local', l[1])
    assert.is_nil(l[2])
  end)
end)
