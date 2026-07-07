-- Specs for the statusline public API and the last-query-info surface. Drawer
-- behavior is driven through an injected drawer (dependency injection over the
-- global singleton); the `db_ui#statusline` autoload interface is exercised directly.

local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')

-- A drawer over an instance seeded with injected connections. The connector
-- echoes the url back, so entries "connect" offline and b:db is set.
local function make_drawer(g_dbs, overrides)
  local cfg = config.resolve(
    vim.tbl_extend('force', { save_location = '/tmp/dbui_statusline', drawer = { show_help = false } }, overrides or {})
  )
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

describe('statusline', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
    vim.cmd('silent! %bwipeout!')
  end)

  it("returns '' for a buffer with no dbui contract that is not a dbout buffer", function()
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' })
    vim.cmd('enew')
    assert.equals('', d:statusline())
  end)

  it('renders prefix + db_name -> schema -> table from the b:dbui_* contract', function()
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' })
    vim.cmd('enew')
    vim.b.dbui_db_key_name = entry_named(d, 'qa').key_name
    vim.b.dbui_schema_name = 'public'
    vim.b.dbui_table_name = 'contacts'
    assert.equals('Dadbod-UI: qa -> public -> contacts', d:statusline())
  end)

  it('drops empty fields from the join', function()
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' })
    vim.cmd('enew')
    vim.b.dbui_db_key_name = entry_named(d, 'qa').key_name
    vim.b.dbui_schema_name = ''
    vim.b.dbui_table_name = 'contacts'
    assert.equals('Dadbod-UI: qa -> contacts', d:statusline())
  end)

  it('honors custom prefix, separator and show order', function()
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' })
    vim.cmd('enew')
    vim.b.dbui_db_key_name = entry_named(d, 'qa').key_name
    vim.b.dbui_schema_name = 'public'
    vim.b.dbui_table_name = 'contacts'
    local out = d:statusline({ prefix = 'db=', separator = ' | ', show = { 'table', 'db_name' } })
    assert.equals('db=contacts | qa', out)
  end)

  it("reports the last query time on a dbout buffer, '' before any query ran", function()
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' })
    vim.cmd('enew')
    vim.bo.filetype = 'dbout'
    assert.equals('', d:statusline())
    d:query().last_query_time = '0.012'
    assert.equals('Last query time: 0.012 sec.', d:statusline())
  end)

  it('is reachable through the db_ui#statusline autoload interface', function()
    vim.cmd('silent! %bwipeout!')
    assert.equals('', vim.fn['db_ui#statusline']())
    assert.equals('', vim.fn['db_ui#statusline']({ prefix = 'x' }))
  end)
end)

describe('last query info', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('returns the recorded query and time', function()
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' })
    local q = d:query()
    assert.same({ last_query = {}, last_query_time = '' }, q:get_last_query_info())
    q.last_query = { 'SELECT 1;' }
    q.last_query_time = '0.003'
    assert.same({ last_query = { 'SELECT 1;' }, last_query_time = '0.003' }, q:get_last_query_info())
  end)
end)
