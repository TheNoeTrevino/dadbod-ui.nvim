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
    d = make_drawer({ dev = 'postgres://h/dev' }, { drawer = { show_help = false } })
    d:open()
    assert.equals('▸ dev', lines(d)[1])
  end)

  -- Any help line whose text contains `needle`.
  local function has(float_lines, needle)
    for _, line in ipairs(float_lines) do
      if line:find(needle, 1, true) then
        return true
      end
    end
    return false
  end

  it('opens a floating window on first toggle and closes it on second', function()
    d = make_drawer({ dev = 'postgres://h/dev' }, { drawer = { show_help = false } })
    d:open()
    assert.equals('▸ dev', lines(d)[1])

    d:toggle_help()
    assert.is_truthy(d.help_winid)
    assert.is_true(vim.api.nvim_win_is_valid(d.help_winid))

    local float_buf = vim.api.nvim_win_get_buf(d.help_winid)
    local float_lines = vim.api.nvim_buf_get_lines(float_buf, 0, -1, false)
    -- Sectioned by context, each header followed by its mappings.
    assert.is_truthy(vim.tbl_contains(float_lines, 'Sidebar'))
    assert.is_truthy(vim.tbl_contains(float_lines, 'Query Buffer'))
    assert.is_truthy(vim.tbl_contains(float_lines, 'DB Results'))
    -- Sidebar entries, now key-aligned and aggregating aliases (o / <CR>).
    assert.is_truthy(has(float_lines, 'o / <CR>'))
    assert.is_truthy(has(float_lines, 'Open/Toggle selected item'))
    assert.is_truthy(has(float_lines, 'Toggle database details'))
    assert.is_truthy(has(float_lines, 'Duplicate connection'))
    -- Query + results mappings now surface too (they were missing before).
    assert.is_truthy(has(float_lines, 'Edit bind parameters'))
    assert.is_truthy(has(float_lines, 'Jump to the foreign key table'))

    -- drawer buffer is unchanged — help is not rendered inline
    assert.equals('▸ dev', lines(d)[1])

    d:toggle_help()
    assert.is_nil(d.help_winid)
  end)

  it('omits an action whose key is set to none, and rebinds from config', function()
    d = make_drawer({ dev = 'postgres://h/dev' }, {
      drawer = { show_help = false },
      mappings = { sidebar = { duplicate = { key = 'none' }, delete = { key = 'x' } } },
    })
    d:open()
    d:toggle_help()
    local float_buf = vim.api.nvim_win_get_buf(d.help_winid)
    local float_lines = vim.api.nvim_buf_get_lines(float_buf, 0, -1, false)
    -- Disabled action is gone from help; the surviving one keeps its description.
    assert.is_falsy(has(float_lines, 'Duplicate connection'))
    assert.is_truthy(has(float_lines, 'Delete selected item'))
    d:toggle_help()
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
    d = make_drawer({ dev = 'postgres://h/dev' }, { drawer = { show_help = false } })
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
    d = make_drawer({}, { drawer = { show_help = false } })
    d:open()
    local l = lines(d)
    assert.equals('" No connections', l[1])
    assert.is_truthy(l[2]:find('Add connection'))
  end)
end)
