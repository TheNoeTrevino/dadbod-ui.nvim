-- Specs for find_buffer (`:DBUIFindBuffer`): adopting a bare buffer into a db
-- context, revealing an already-attached buffer in the drawer, and the multi-db
-- selection. Driven through an injected drawer (DI over the global singleton).

local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')

local function make_drawer(g_dbs, overrides)
  local cfg =
    config.resolve(vim.tbl_extend('force', { save_location = '/tmp/dbui_find', show_help = false }, overrides or {}))
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

describe('find_buffer', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
    vim.cmd('silent! %bwipeout!')
  end)

  it('errors when there are no database entries', function()
    d = make_drawer({})
    local notify = require('dadbod-ui.notifications')
    local msg
    local saved = notify.error
    notify.error = function(m)
      msg = m
    end
    d:find_buffer()
    notify.error = saved
    assert.equals('No database entries found in DBUI.', msg)
  end)

  it('adopts a bare buffer under a lone connection, writing the contract', function()
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' })
    d:open()
    local entry = entry_named(d, 'qa')
    -- A NAMED buffer with no dbui contract, focused in a non-drawer window.
    -- (An unnamed buffer is refused -- see the dedicated spec below.)
    vim.cmd('wincmd p')
    vim.cmd('edit /tmp/dbui_find/adopt.sql')
    d:find_buffer()
    assert.equals(entry.key_name, vim.b.dbui_db_key_name)
    assert.equals(entry.conn, vim.b.db)
    assert.is_true(entry.buffers.expanded)
  end)

  it('refuses to adopt an unnamed buffer, never inserting a phantom node', function()
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' })
    d:open()
    local entry = entry_named(d, 'qa')
    local notify = require('dadbod-ui.notifications')
    local msg
    local saved = notify.error
    notify.error = function(m)
      msg = m
    end
    -- A bare, unnamed buffer in a non-drawer window.
    vim.cmd('wincmd p')
    vim.cmd('enew')
    d:find_buffer()
    notify.error = saved
    assert.matches('unnamed buffer', msg)
    assert.is_nil(vim.b.dbui_db_key_name)
    assert.equals(0, #entry.buffers.list)
  end)

  it('reveals a buffer that already carries the contract and moves the cursor onto it', function()
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' })
    d:open()
    local entry = entry_named(d, 'qa')
    -- Open a real query buffer so it is tracked with a name in the tree.
    d:query():open({ type = 'query', key_name = entry.key_name }, 'edit')
    local bufname = vim.api.nvim_buf_get_name(0)
    d:find_buffer()
    local node = d.content[vim.api.nvim_win_get_cursor(d.winid)[1]]
    assert.equals('buffer', node.type)
    assert.equals(bufname, node.file_path)
  end)

  it('prompts to select among several connections via the injected picker', function()
    d = make_drawer({ a = 'sqlite:/tmp/a.db', b = 'sqlite:/tmp/b.db' })
    d:open()
    local chosen
    d:query().select = function(items, _, on_choice)
      chosen = items
      on_choice(items[2])
    end
    vim.cmd('wincmd p')
    vim.cmd('edit /tmp/dbui_find/adopt_multi.sql')
    d:find_buffer()
    assert.equals(2, #chosen)
    local picked = d.instance.dbs[chosen[2].key_name]
    assert.equals(picked.key_name, vim.b.dbui_db_key_name)
  end)
end)
