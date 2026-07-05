-- Specs for the M11 events/commands wiring: the `User DBUIOpened` autocmd fired
-- on a real drawer open, and the presence of the public user commands registered
-- by plugin/dadbod-ui.lua.

local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')

local function make_drawer(g_dbs)
  local cfg = config.resolve({ save_location = '/tmp/dbui_events', drawer = { show_help = false } })
  local instance = state.new(cfg):populate({ env = {}, g_dbs = g_dbs, file_entries = {} })
  local d = drawer_mod.new(instance)
  d.connector = function(url)
    return url
  end
  return d
end

describe('User DBUIOpened', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('fires once on a real open, not when focusing an already-open drawer', function()
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' })
    local fired = 0
    local group = vim.api.nvim_create_augroup('dbui_opened_test', { clear = true })
    vim.api.nvim_create_autocmd('User', {
      group = group,
      pattern = 'DBUIOpened',
      callback = function()
        fired = fired + 1
      end,
    })
    d:open()
    d:open() -- already open: focuses without re-firing
    vim.api.nvim_del_augroup_by_id(group)
    assert.equals(1, fired)
  end)
end)

describe('public user commands', function()
  it('registers the M11 commands', function()
    -- The boot file is not sourced by minimal_init; load it (idempotent via its
    -- own `g:loaded_dadbod_ui` guard) so its user commands exist.
    vim.cmd('runtime plugin/dadbod-ui.lua')
    local commands = vim.api.nvim_get_commands({})
    for _, name in ipairs({ 'DBUIFindBuffer', 'DBUIRenameBuffer', 'DBUILastQueryInfo' }) do
      assert.is_not_nil(commands[name], name .. ' should be registered')
    end
  end)
end)
