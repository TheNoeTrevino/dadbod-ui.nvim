local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')

local function make_drawer(g_dbs, overrides)
  local cfg = config.resolve(vim.tbl_extend('force', { save_location = '/tmp/dbui_help' }, overrides or {}))
  local instance = state.new(cfg):populate({ env = {}, g_dbs = g_dbs or {}, file_entries = {} })
  return drawer_mod.new(instance)
end

local function lines(d)
  return vim.api.nvim_buf_get_lines(d.bufnr, 0, -1, false)
end

describe('drawer: help banner', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('shows the help banner by default', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    d:open()
    assert.equals('" Press ? for help', lines(d)[1])
    assert.equals('▸ dev', lines(d)[3]) -- after banner + blank line
  end)

  it('omits the banner when show_help is false', function()
    d = make_drawer({ dev = 'postgres://h/dev' }, { show_help = false })
    d:open()
    assert.equals('▸ dev', lines(d)[1])
  end)

  it('opens a floating window on first toggle and closes it on second', function()
    d = make_drawer({ dev = 'postgres://h/dev' }, { show_help = false })
    d:open()
    assert.equals('▸ dev', lines(d)[1])

    d:toggle_help()
    assert.is_truthy(d.help_winid)
    assert.is_true(vim.api.nvim_win_is_valid(d.help_winid))

    local float_buf = vim.api.nvim_win_get_buf(d.help_winid)
    local float_lines = vim.api.nvim_buf_get_lines(float_buf, 0, -1, false)
    assert.is_truthy(vim.tbl_contains(float_lines, '  o - Open/Toggle selected item'))
    assert.is_truthy(vim.tbl_contains(float_lines, '  H - Toggle database details'))
    assert.is_truthy(vim.tbl_contains(float_lines, '  D - Duplicate connection'))

    -- drawer buffer is unchanged — help is not rendered inline
    assert.equals('▸ dev', lines(d)[1])

    d:toggle_help()
    assert.is_nil(d.help_winid)
  end)
end)

describe('drawer: connection details', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('appends (scheme - source) when details are on', function()
    d = make_drawer({ dev = 'postgres://h/dev' }, { show_help = false })
    d:open()
    assert.equals('▸ dev', lines(d)[1])
    d:toggle_details()
    assert.equals('▸ dev (postgresql - g:dbs)', lines(d)[1])
    d:toggle_details()
    assert.equals('▸ dev', lines(d)[1])
  end)
end)

describe('drawer: empty state', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('shows the add-connection prompt when there are no connections', function()
    d = make_drawer({}, { show_help = false })
    d:open()
    local l = lines(d)
    assert.equals('" No connections', l[1])
    assert.is_truthy(l[2]:find('Add connection'))
  end)
end)
