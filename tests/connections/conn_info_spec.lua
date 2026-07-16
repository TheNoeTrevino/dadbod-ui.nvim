-- Specs for the db_ui#get_conn_info autoload entry point (M7 fix): third-party
-- integrations (e.g. vim-dadbod-completion) call db_ui#get_conn_info from a
-- FileType sql autocmd; it must resolve against the plugin's state.

local dadbod_ui = require('dadbod-ui')
local state = require('dadbod-ui.state')

describe('db_ui#get_conn_info', function()
  after_each(function()
    vim.g.dbs = nil
    dadbod_ui.reset()
  end)

  it('returns the connection info shape for a known key', function()
    vim.g.dbs = { { name = 'ci', url = 'sqlite:/tmp/ci.db' } }
    dadbod_ui.reset()
    local inst = state.get()
    local key
    for _, r in ipairs(inst.dbs_list) do
      if r.name == 'ci' then
        key = r.key_name
      end
    end
    assert.is_not_nil(key)
    local info = dadbod_ui.get_conn_info(key)
    assert.equals('sqlite', info.scheme)
    assert.equals(0, info.connected) -- not connected yet
    assert.same({}, info.tables)
    assert.is_string(info.url)
  end)

  it('is reachable through the db_ui# autoload interface', function()
    vim.g.dbs = { { name = 'ci', url = 'sqlite:/tmp/ci.db' } }
    dadbod_ui.reset()
    local inst = state.get()
    local key
    for _, r in ipairs(inst.dbs_list) do
      if r.name == 'ci' then
        key = r.key_name
      end
    end
    local info = vim.fn['db_ui#get_conn_info'](key)
    assert.equals('sqlite', info.scheme)
  end)

  it('returns an empty table for an unknown key', function()
    assert.same({}, dadbod_ui.get_conn_info('does-not-exist'))
  end)
end)

describe('public execute API', function()
  it('execute_query routes to the dadbod bridge; execute_selection is exposed', function()
    local bridge = require('dadbod-ui.bridge')
    local saved = bridge.execute_buffer
    local called = false
    bridge.execute_buffer = function()
      called = true
    end
    pcall(dadbod_ui.execute_query)
    bridge.execute_buffer = saved
    assert.is_true(called)
    assert.is_function(dadbod_ui.execute_selection)
  end)
end)
