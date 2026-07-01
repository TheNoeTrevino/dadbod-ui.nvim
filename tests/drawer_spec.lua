local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')

-- Build a drawer over an instance seeded with injected connections.
local function make_drawer(g_dbs, overrides)
  local cfg =
    config.resolve(vim.tbl_extend('force', { save_location = '/tmp/dbui_drawer', show_help = false }, overrides or {}))
  local instance = state.new(cfg):populate({ env = {}, g_dbs = g_dbs, file_entries = {} })
  local d = drawer_mod.new(instance)
  -- Keep render specs offline: expanding a connection would otherwise connect.
  -- The drawer-expand path connects via `async_connector`; return an empty conn
  -- (state.is_connected treats '' as not connected) so no real probe is spawned.
  d.connector = function()
    return ''
  end
  d.async_connector = function(_, on_result)
    -- Defer like the real (vim.system-backed) backend so the loading spinner is
    -- observable between expand and resolution.
    vim.schedule(function()
      on_result(true, '')
    end)
  end
  return d
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
    -- New query renders immediately; the db node keeps its fold icon and trails
    -- the connection spinner until the deferred (blocking) connect resolves.
    local key = d.content[1].key_name
    assert.equals('  + New query', lines(d)[2])
    assert.equals('▾ dev ' .. require('dadbod-ui.spinners').dots[1], lines(d)[1])
    vim.wait(500, function()
      return not d.instance.dbs[key].loading
    end)
    assert.equals('▾ dev', lines(d)[1]) -- loading cleared (offline connector: not connected)
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
