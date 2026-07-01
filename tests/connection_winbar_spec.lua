-- Specs for the query-buffer connection winbar (issue #29): the pure `group/name`
-- formatter (grouped / ungrouped / `%`-escaping) and its application as a
-- right-aligned winbar on the query window (set when enabled, absent when the
-- `show_buffer_connection` toggle is off). No DB binary is needed.

local query = require('dadbod-ui.query')
local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')

local function make_drawer(g_dbs, overrides)
  local cfg =
    config.resolve(vim.tbl_extend('force', { save_location = '/tmp/dbui_winbar', show_help = false }, overrides or {}))
  local instance = state.new(cfg):populate({ env = {}, g_dbs = g_dbs, file_entries = {} })
  local d = drawer_mod.new(instance)
  d.connector = function(url)
    return url
  end
  return d
end

local function entry_named(d, name)
  for _, record in ipairs(d.instance.dbs_list) do
    if record.name == name then
      return d.instance.dbs[record.key_name]
    end
  end
end

describe('connection winbar: formatter', function()
  it('ungrouped connection shows just the name (no leading slash)', function()
    local wb = query.connection_winbar({ group = '', name = 'qa' })
    assert.equals('%=%#DadbodUIWinbarConnection# qa ', wb)
  end)

  it('grouped connection shows group/name', function()
    local wb = query.connection_winbar({ group = 'prod', name = 'orders' })
    assert.equals('%=%#DadbodUIWinbarConnection# prod/orders ', wb)
  end)

  it('escapes `%` so a name cannot inject statusline items', function()
    local wb = query.connection_winbar({ group = 'a%b', name = 'c%d' })
    assert.equals('%=%#DadbodUIWinbarConnection# a%%b/c%%d ', wb)
  end)
end)

describe('connection winbar: application', function()
  local d
  local query_bufs = {}

  after_each(function()
    for _, b in ipairs(query_bufs) do
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
    query_bufs = {}
    if d then
      -- Guarded: a test that swaps buffers between windows can leave the drawer as
      -- the last window, where :close would raise E444; the teardown still cleans up.
      pcall(function()
        d:close()
      end)
      d = nil
    end
    -- Clear any leftover window-local winbars so one test can't leak into the next.
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      pcall(vim.api.nvim_set_option_value, 'winbar', '', { win = win })
    end
  end)

  it('sets the connection winbar on the query window when enabled', function()
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' })
    d:open()
    local entry = entry_named(d, 'qa')
    d:query():open({ type = 'query', key_name = entry.key_name }, 'edit')
    query_bufs[#query_bufs + 1] = vim.api.nvim_get_current_buf()

    local winbar = vim.api.nvim_get_option_value('winbar', { win = 0 })
    assert.equals(query.connection_winbar(entry), winbar)
    assert.is_truthy(winbar:find('qa', 1, true))
  end)

  it('clears the winbar when the query buffer leaves its window, then re-applies on re-entry', function()
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' })
    d:open()
    local entry = entry_named(d, 'qa')
    d:query():open({ type = 'query', key_name = entry.key_name }, 'edit')
    local qbuf = vim.api.nvim_get_current_buf()
    query_bufs[#query_bufs + 1] = qbuf
    local win = vim.api.nvim_get_current_win()
    assert.equals(query.connection_winbar(entry), vim.api.nvim_get_option_value('winbar', { win = win }))

    -- Replace the query buffer in its window with a plain scratch buffer: the
    -- BufWinLeave teardown must clear the winbar so the connection can't leak onto
    -- the buffer shown next.
    local other = vim.api.nvim_create_buf(true, false)
    query_bufs[#query_bufs + 1] = other
    vim.api.nvim_win_set_buf(win, other)
    assert.equals('', vim.api.nvim_get_option_value('winbar', { win = win }))

    -- Re-entering the query buffer re-applies its connection winbar (BufWinEnter).
    vim.api.nvim_win_set_buf(win, qbuf)
    assert.equals(query.connection_winbar(entry), vim.api.nvim_get_option_value('winbar', { win = win }))
  end)

  it('leaves the winbar unset when show_buffer_connection is disabled', function()
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' }, { show_buffer_connection = false })
    d:open()
    local entry = entry_named(d, 'qa')
    d:query():open({ type = 'query', key_name = entry.key_name }, 'edit')
    query_bufs[#query_bufs + 1] = vim.api.nvim_get_current_buf()

    assert.equals('', vim.api.nvim_get_option_value('winbar', { win = 0 }))
  end)
end)
