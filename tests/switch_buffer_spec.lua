-- Specs for switch_buffer (`:DBUISwitchBuffer`): reassigning an already-attached
-- query buffer to another connection, rewriting the contract + winbar and moving
-- the buffer's tracking between connections. Driven through an injected drawer.

local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')

local function make_drawer(g_dbs, overrides)
  local cfg =
    config.resolve(vim.tbl_extend('force', { save_location = '/tmp/dbui_switch', show_help = false }, overrides or {}))
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

describe('switch_buffer', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
    vim.cmd('silent! %bwipeout!')
  end)

  it('reassigns the contract, winbar, and buffer tracking to the chosen db', function()
    d = make_drawer({ a = 'sqlite:/tmp/a.db', b = 'sqlite:/tmp/b.db' }, { show_buffer_connection = true })
    d:open()
    local a = entry_named(d, 'a')
    local b = entry_named(d, 'b')
    -- Open a real query buffer on connection a, in a non-drawer window.
    d:query():open({ type = 'query', key_name = a.key_name }, 'edit')
    local bufname = vim.api.nvim_buf_get_name(0)
    local bufnr = vim.api.nvim_get_current_buf()
    assert.equals(a.key_name, vim.b.dbui_db_key_name)
    assert.is_true(vim.tbl_contains(a.buffers.list, bufname))

    -- Pick connection b from the injected selector.
    d:query().select = function(items, _, on_choice)
      on_choice(items[1])
    end
    d:switch_buffer()

    -- Contract now points at b, and the tracking moved with it.
    assert.equals(b.key_name, vim.b[bufnr].dbui_db_key_name)
    assert.equals(b.conn, vim.b[bufnr].db)
    assert.is_true(vim.tbl_contains(b.buffers.list, bufname))
    assert.is_false(vim.tbl_contains(a.buffers.list, bufname))

    -- Winbar reflects the new connection.
    local win = vim.fn.bufwinid(bufnr)
    assert.equals(
      require('dadbod-ui.query').connection_winbar(b),
      vim.api.nvim_get_option_value('winbar', { win = win })
    )
  end)

  it('carries the table/schema/bind-param context across the switch', function()
    d = make_drawer({ a = 'sqlite:/tmp/a.db', b = 'sqlite:/tmp/b.db' })
    d:open()
    local a = entry_named(d, 'a')
    local b = entry_named(d, 'b')
    d:query():open({ type = 'query', key_name = a.key_name }, 'edit')
    local bufnr = vim.api.nvim_get_current_buf()
    vim.b[bufnr].dbui_table_name = 'users'
    vim.b[bufnr].dbui_schema_name = 'public'
    vim.b[bufnr].dbui_bind_params = { id = '7' }

    d:query().select = function(items, _, on_choice)
      on_choice(items[1])
    end
    d:switch_buffer()

    assert.equals(b.key_name, vim.b[bufnr].dbui_db_key_name)
    assert.equals('users', vim.b[bufnr].dbui_table_name)
    assert.equals('public', vim.b[bufnr].dbui_schema_name)
    assert.equals('7', vim.b[bufnr].dbui_bind_params.id)
  end)

  it('does nothing when the picker is cancelled', function()
    d = make_drawer({ a = 'sqlite:/tmp/a.db', b = 'sqlite:/tmp/b.db' })
    d:open()
    local a = entry_named(d, 'a')
    d:query():open({ type = 'query', key_name = a.key_name }, 'edit')
    local bufnr = vim.api.nvim_get_current_buf()
    d:query().select = function(_, _, on_choice)
      on_choice(nil)
    end
    d:switch_buffer()
    assert.equals(a.key_name, vim.b[bufnr].dbui_db_key_name)
  end)

  it('notifies when there is no other connection to switch to', function()
    d = make_drawer({ a = 'sqlite:/tmp/a.db' })
    d:open()
    local a = entry_named(d, 'a')
    d:query():open({ type = 'query', key_name = a.key_name }, 'edit')
    local notify = require('dadbod-ui.notifications')
    local msg
    local saved = notify.info
    notify.info = function(m)
      msg = m
    end
    d:switch_buffer()
    notify.info = saved
    assert.equals('No other connection to switch this buffer to.', msg)
  end)

  it('falls back to find_buffer for a bare buffer', function()
    d = make_drawer({ a = 'sqlite:/tmp/a.db' })
    d:open()
    vim.cmd('wincmd p')
    vim.cmd('enew')
    local called = false
    d.find_buffer = function()
      called = true
    end
    d:switch_buffer()
    assert.is_true(called)
  end)

  it('switches directly to a named connection without prompting', function()
    d = make_drawer({ a = 'sqlite:/tmp/a.db', b = 'sqlite:/tmp/b.db' })
    d:open()
    local a = entry_named(d, 'a')
    local b = entry_named(d, 'b')
    d:query():open({ type = 'query', key_name = a.key_name }, 'edit')
    local bufname = vim.api.nvim_buf_get_name(0)
    local bufnr = vim.api.nvim_get_current_buf()
    -- No picker is consulted on the direct path.
    d:query().select = function()
      error('picker should not be shown for a named switch')
    end
    local ok, err = d:switch_buffer('b')
    assert.is_true(ok, err)
    assert.equals(b.key_name, vim.b[bufnr].dbui_db_key_name)
    assert.is_true(vim.tbl_contains(b.buffers.list, bufname))
    assert.is_false(vim.tbl_contains(a.buffers.list, bufname))
  end)

  it('errors for an unknown named target, leaving the buffer put', function()
    d = make_drawer({ a = 'sqlite:/tmp/a.db', b = 'sqlite:/tmp/b.db' })
    d:open()
    local a = entry_named(d, 'a')
    d:query():open({ type = 'query', key_name = a.key_name }, 'edit')
    local bufnr = vim.api.nvim_get_current_buf()
    local ok, err = d:switch_buffer('nope')
    assert.is_false(ok)
    assert.is_truthy(err and err:match('no connection named nope'))
    assert.equals(a.key_name, vim.b[bufnr].dbui_db_key_name)
  end)

  it('errors on a named switch from a bare buffer (no query contract)', function()
    d = make_drawer({ a = 'sqlite:/tmp/a.db', b = 'sqlite:/tmp/b.db' })
    d:open()
    vim.cmd('wincmd p')
    vim.cmd('enew')
    local ok, err = d:switch_buffer('b')
    assert.is_false(ok)
    assert.is_truthy(err and err:match('not a dadbod%-ui query buffer'))
  end)
end)
