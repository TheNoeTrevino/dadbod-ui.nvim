local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')

describe('state: instance paths', function()
  it('resolves save and connections paths from config', function()
    local inst = state.new(config.resolve({ save_location = '/tmp/dbui_test' }))
    assert.equals('/tmp/dbui_test', inst.save_path)
    assert.equals('/tmp/dbui_test/connections.json', inst.connections_path)
  end)

  it('leaves paths empty when unset', function()
    local inst = state.new(config.resolve({ save_location = '', tmp_query_location = '' }))
    assert.equals('', inst.save_path)
    assert.is_nil(inst.connections_path)
    assert.equals('', inst.tmp_location)
  end)
end)

describe('state: populate', function()
  local cfg = config.resolve({ save_location = '/tmp/dbui_test' })

  it('builds dbs_list and a map keyed by key_name', function()
    local inst = state.new(cfg):populate({
      env = {},
      g_dbs = {
        { name = 'pg', url = 'postgres://h/shop', group = 'Local' },
      },
      file_entries = {},
    })
    assert.equals(1, #inst.dbs_list)
    local entry = inst.dbs['Local_pg_g:dbs']
    assert.is_not_nil(entry)
    assert.equals('pg', entry.name)
    assert.equals('Local', entry.group)
    -- url is resolved at storage time, so the scheme is canonical
    assert.equals('postgresql', entry.scheme)
  end)

  it('derives db_name from the url path, falling back to the name', function()
    local inst = state.new(cfg):populate({
      env = {},
      g_dbs = { withpath = 'postgres://h/inventory', nopath = 'postgres://h/' },
      file_entries = {},
    })
    assert.equals('inventory', inst.dbs['withpath_g:dbs'].db_name)
    assert.equals('nopath', inst.dbs['nopath_g:dbs'].db_name)
  end)

  it('computes a grouped save path', function()
    local inst = state.new(cfg):populate({
      env = {},
      g_dbs = { { name = 'pg', url = 'postgres://h/a', group = 'Local' } },
      file_entries = {},
    })
    assert.equals('/tmp/dbui_test/Local_pg', inst.dbs['Local_pg_g:dbs'].save_path)
  end)

  it('connections_list reports name/url/source and not-connected', function()
    local inst = state.new(cfg):populate({
      env = {},
      g_dbs = { dev = 'postgres://h/dev' },
      file_entries = {},
    })
    local list = inst:connections_list()
    assert.equals(1, #list)
    assert.equals('dev', list[1].name)
    assert.equals('g:dbs', list[1].source)
    assert.equals(false, list[1].is_connected)
  end)
end)

describe('state: public api', function()
  it('exposes connections_list through the module', function()
    local ui = require('dadbod-ui')
    ui.setup({ save_location = vim.fn.tempname() }) -- empty dir, no file
    assert.is_table(ui.connections_list())
  end)
end)
