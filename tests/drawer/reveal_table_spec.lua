local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')
local ids = require('dadbod-ui.drawer.ids')
local helper = require('helper')

-- A drawer over one schema connection (postgres) and one flat one (sqlite),
-- with introspection data seeded directly -- reveal/goto work purely off
-- entry data, no live connection.
local function make_drawer()
  local cfg = config.resolve({ save_location = '/tmp/dbui_reveal', drawer = { show_help = false } })
  local instance = state.new(cfg):populate({
    env = {},
    g_dbs = {
      { name = 'pg', url = 'postgres://h/pg' },
      { name = 'lite', url = 'sqlite:/tmp/dbui_reveal.db' },
    },
    file_entries = {},
  })
  local d = drawer_mod.new(instance)
  d.connector = function()
    return ''
  end
  d.async_connector = function(_, on_result)
    vim.schedule(function()
      on_result(true, '')
    end)
  end
  local pg = instance.dbs[instance.dbs_list[1].key_name]
  pg.tables = { 'logs', 'orders', 'users' }
  pg.schemas = {
    list = { 'audit', 'public' },
    items = { public = { 'orders', 'users' }, audit = { 'logs', 'users' } },
  }
  local lite = instance.dbs[instance.dbs_list[2].key_name]
  lite.tables = { 'inventory', 'users' }
  return d, pg, lite
end

local function node_under_cursor(d)
  return d.content[vim.api.nvim_win_get_cursor(d.winid)[1]]
end

describe('drawer: reveal_table', function()
  local d, pg, lite
  before_each(function()
    helper.clean_ui()
    d, pg, lite = make_drawer()
  end)
  after_each(function()
    d:close()
  end)

  it('expands the chain and lands on a schema-qualified table', function()
    assert.is_true(d:reveal_table(pg.key_name, 'users', 'audit'))
    local node = node_under_cursor(d)
    assert.equals('table', node.type)
    assert.equals('users', node.table)
    assert.equals('audit', node.schema)
    assert.is_true(d:is_expanded(ids.db(pg.key_name)))
    assert.is_true(d:is_expanded(ids.section(pg.key_name, 'schemas')))
    assert.is_true(d:is_expanded(ids.schema(pg.key_name, 'audit')))
  end)

  it('lands on a flat-adapter table under the tables section', function()
    assert.is_true(d:reveal_table(lite.key_name, 'inventory', ''))
    local node = node_under_cursor(d)
    assert.equals('table', node.type)
    assert.equals('inventory', node.table)
    assert.equals('', node.schema)
    assert.is_true(d:is_expanded(ids.section(lite.key_name, 'tables')))
  end)

  it('distinguishes the same table name across schemas', function()
    assert.is_true(d:reveal_table(pg.key_name, 'users', 'public'))
    assert.equals('public', node_under_cursor(d).schema)
  end)

  it('returns false for an unknown table or connection without landing', function()
    assert.is_false(d:reveal_table(pg.key_name, 'missing', 'public'))
    assert.is_false(d:reveal_table('nope', 'users', 'public'))
  end)
end)

describe('drawer: goto_table', function()
  local d, pg, lite

  -- Show `sql` in the current window as a query buffer bound to `entry`, with
  -- the cursor at (row, col), 1-based row / 0-based col like nvim_win_set_cursor.
  local function sql_buffer(entry, sql, row, col, schema)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(sql, '\n'))
    vim.api.nvim_set_current_buf(buf)
    vim.b[buf].dbui_db_key_name = entry.key_name
    vim.b[buf].dbui_schema_name = schema or ''
    vim.api.nvim_win_set_cursor(0, { row, col })
  end

  before_each(function()
    helper.clean_ui()
    d, pg, lite = make_drawer()
  end)
  after_each(function()
    d:close()
  end)

  it('jumps to a plain table name through the buffer connection', function()
    sql_buffer(lite, 'select * from inventory', 1, 16)
    d:goto_table()
    assert.is_true(d:is_open())
    local node = node_under_cursor(d)
    assert.equals('inventory', node.table)
  end)

  it('resolves a schema-qualified name', function()
    sql_buffer(pg, 'select * from audit.logs', 1, 21)
    d:goto_table()
    local node = node_under_cursor(d)
    assert.equals('logs', node.table)
    assert.equals('audit', node.schema)
  end)

  it("prefers the buffer's schema for an unqualified name", function()
    sql_buffer(pg, 'select * from users', 1, 15, 'audit')
    d:goto_table()
    assert.equals('audit', node_under_cursor(d).schema)
  end)

  it('stays quiet when the word is not a known table', function()
    sql_buffer(pg, 'select * from nothere', 1, 16)
    d:goto_table()
    assert.is_false(d:is_open())
  end)

  it('stays quiet outside a query buffer', function()
    vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, true))
    d:goto_table()
    assert.is_false(d:is_open())
  end)
end)
