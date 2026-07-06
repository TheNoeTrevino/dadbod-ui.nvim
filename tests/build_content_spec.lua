-- Specs for the pure build half of the drawer render (M10 prerequisite):
-- Drawer:build_content() rebuilds the node list from the instance WITHOUT an
-- open window, stores it on self.content (navigation indexes that), and returns
-- it. These assert the node shapes directly -- never calling d:open().

local drawer_mod = require('dadbod-ui.drawer')
local ids = require('dadbod-ui.drawer.ids')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')

-- A drawer over an instance seeded with injected connections, connector stubbed
-- offline. Mirrors tests/schema_introspection_spec.lua's helper.
local function make_drawer(g_dbs, overrides)
  local cfg = config.resolve(
    vim.tbl_extend('force', { save_location = '/tmp/dbui_schemas', drawer = { show_help = false } }, overrides or {})
  )
  local instance = state.new(cfg):populate({ env = {}, g_dbs = g_dbs, file_entries = {} })
  local d = drawer_mod.new(instance)
  d.connector = function()
    return ''
  end
  return d
end

describe('drawer build_content (no window)', function()
  it('builds the node list without opening the drawer', function()
    local d = make_drawer({ dev = 'postgres://h/dev' })
    assert.is_false(d:is_open())
    local nodes = d:build_content()
    assert.is_false(d:is_open()) -- still no window after building
    assert.is_table(nodes)
    -- a single collapsed db node for the one connection
    assert.equals(1, #nodes)
    local db = nodes[1]
    assert.equals('db', db.type)
    assert.equals('dev', db.label)
    assert.equals(0, db.level)
    assert.equals('toggle', db.action)
    assert.is_false(db.expanded)
    assert.equals(d:toggle_icon('db', false), db.icon)
  end)

  it('returns the same table stored on self.content', function()
    local d = make_drawer({ dev = 'postgres://h/dev' })
    local nodes = d:build_content()
    assert.are.equal(nodes, d.content) -- identity: navigation indexes self.content
  end)

  it('emits the empty-state nodes when there are no connections', function()
    local d = make_drawer({})
    local nodes = d:build_content()
    assert.equals(2, #nodes)
    assert.equals('help', nodes[1].type)
    assert.equals('" No connections', nodes[1].label)
    assert.equals('add_connection', nodes[2].type)
    assert.equals('call_method', nodes[2].action)
  end)

  it('expands nested section nodes purely from instance + expand-map state', function()
    local d = make_drawer({ qa = 'sqlite:/tmp/whatever.db' })
    -- seed expand state directly; no window, no render
    local record = d.instance.dbs_list[1]
    local entry = d.instance.dbs[record.key_name]
    d:set_expanded(ids.db(entry.key_name), true)
    d:set_expanded(ids.section(entry.key_name, 'tables'), true)
    entry.tables = { list = { 'contacts' } }
    local nodes = d:build_content()
    local types = vim.tbl_map(function(n)
      return n.type
    end, nodes)
    assert.is_true(vim.tbl_contains(types, 'db'))
    assert.is_true(vim.tbl_contains(types, 'tables'))
    assert.is_true(vim.tbl_contains(types, 'table'))
    -- the table node carries its name and lives under the section
    local found = vim.iter(nodes):find(function(n)
      return n.type == 'table'
    end)
    assert.is_truthy(found)
    assert.equals('contacts', found.table)
  end)

  it('honours show_help by prepending the help hint nodes', function()
    local d = make_drawer({ dev = 'postgres://h/dev' }, { drawer = { show_help = true } })
    local nodes = d:build_content()
    assert.equals('" Press ? for help', nodes[1].label)
    assert.equals('help', nodes[1].type)
  end)
end)
