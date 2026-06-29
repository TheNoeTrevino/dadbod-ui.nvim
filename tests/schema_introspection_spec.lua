-- Specs for schema/table introspection in the drawer (M6): folding parsed
-- results into the entry, honoring hide_schemas, rendering the Schemas/Tables
-- sections, schema-support detection, and a guarded end-to-end sqlite expand.

local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')
local notifications = require('dadbod-ui.notifications')

-- A drawer over an instance seeded with injected connections. The connector is
-- stubbed offline by default; integration tests opt back into the real one.
local function make_drawer(g_dbs, overrides)
  local cfg = config.resolve(vim.tbl_extend('force', { save_location = '/tmp/dbui_schemas', show_help = false }, overrides or {}))
  local instance = state.new(cfg):populate({ env = {}, g_dbs = g_dbs, file_entries = {} })
  local d = drawer_mod.new(instance)
  d.connector = function()
    return ''
  end
  return d
end

local function lines(d)
  return vim.api.nvim_buf_get_lines(d.bufnr, 0, -1, false)
end

local function entry_named(d, name)
  for _, record in ipairs(d.instance.dbs_list) do
    if record.name == name then
      return d.instance.dbs[record.key_name]
    end
  end
end

describe('schema introspection: apply_schemas', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('folds schemas and (schema, table) rows into the entry', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    local entry = entry_named(d, 'dev')
    d:introspect():apply_schemas(entry, { 'public', 'app' }, {
      { 'public', 'users' },
      { 'public', 'posts' },
      { 'app', 'tasks' },
    })
    assert.same({ 'public', 'app' }, entry.schemas.list)
    assert.same({ 'posts', 'users' }, entry.schemas.items.public.tables.list) -- sorted
    assert.same({ 'tasks' }, entry.schemas.items.app.tables.list)
    -- the flat table list collects every schema's tables
    assert.equals(3, #entry.tables.list)
    -- per-table expand state is seeded
    assert.is_false(entry.schemas.items.public.tables.items.users.expanded)
  end)

  it('drops schemas and tables matching hide_schemas', function()
    d = make_drawer({ dev = 'postgres://h/dev' }, { hide_schemas = { 'information_schema', 'pg_' } })
    local entry = entry_named(d, 'dev')
    d:introspect():apply_schemas(entry, { 'public', 'information_schema', 'pg_catalog' }, {
      { 'public', 'users' },
      { 'information_schema', 'tables' },
      { 'pg_catalog', 'pg_class' },
    })
    assert.same({ 'public' }, entry.schemas.list)
    assert.same({ 'users' }, entry.tables.list)
    assert.is_nil(entry.schemas.items.information_schema)
  end)
end)

describe('schema introspection: rendering', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('renders Schemas -> schema -> tables -> helpers for a schema adapter', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    d:open()
    local entry = entry_named(d, 'dev')
    entry.expanded = true
    entry.schemas.expanded = true
    entry.schemas.list = { 'public' }
    entry.schemas.items = {
      public = {
        expanded = true,
        tables = { expanded = true, list = { 'users' }, items = { users = { expanded = true } } },
      },
    }
    d:render()
    local l = lines(d)
    assert.equals('▾ dev', l[1])
    assert.equals('  + New query', l[2])
    assert.equals('  ▸ Saved queries (0)', l[3]) -- always shown, between New query and Schemas
    assert.equals('  ▾ Schemas (1)', l[4])
    assert.equals('    ▾ public (1)', l[5])
    assert.equals('      ▾ users', l[6]) -- expanded, so its helpers follow
    -- an expanded table lists its adapter helpers (e.g. List) as children
    assert.is_truthy(vim.tbl_contains(l, '        ~ List'))
  end)

  it('renders a Tables section directly for a non-schema adapter (sqlite)', function()
    d = make_drawer({ qa = 'sqlite:/tmp/whatever.db' })
    d:open()
    local entry = entry_named(d, 'qa')
    assert.is_false(entry.schema_support)
    entry.expanded = true
    entry.tables = { expanded = true, list = { 'contacts' }, items = { contacts = { expanded = false } } }
    d:render()
    local l = lines(d)
    assert.equals('▾ qa', l[1])
    assert.is_truthy(vim.tbl_contains(l, '  ▾ Tables (1)'))
    assert.is_truthy(vim.tbl_contains(l, '    ▸ contacts'))
    -- no Schemas section for an adapter without schema support
    assert.is_false(vim.tbl_contains(l, '  ▸ Schemas (0)'))
  end)
end)

describe('schema introspection: connect', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('reports how long a successful connection took', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    d.connector = function()
      return 'postgres://h/dev'
    end
    d:open()
    d:introspect():connect(entry_named(d, 'dev'))
    assert.is_truthy(notifications.get_last_msg():match('Took %d+ms to connect%.'))
  end)
end)

describe('schema introspection: sqlite end-to-end (guarded)', function()
  local d, dir, db_path
  before_each(function()
    if vim.fn.executable('sqlite3') ~= 1 then
      return
    end
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    db_path = dir .. '/qa.db'
    vim.fn.system({
      'sqlite3',
      db_path,
      'CREATE TABLE contacts(id INTEGER, name TEXT); CREATE TABLE notes(id INTEGER);',
    })
  end)
  after_each(function()
    if d then
      d:close()
      d = nil
    end
    if dir then
      vim.fn.delete(dir, 'rf')
      dir, db_path = nil, nil
    end
  end)

  it('connects and lists real tables directly under the connection', function()
    if vim.fn.executable('sqlite3') ~= 1 then
      pending('sqlite3 not installed')
      return
    end
    d = make_drawer({ qa = 'sqlite:' .. db_path })
    d.connector = require('dadbod-ui.bridge').connect -- real connect for sqlite (offline)
    d:open()
    local entry = entry_named(d, 'qa')
    d:introspect():connect(entry)
    assert.is_truthy(entry.conn ~= nil and entry.conn ~= '')
    d:introspect():populate_tables(entry)
    assert.is_true(vim.tbl_contains(entry.tables.list, 'contacts'))
    assert.is_true(vim.tbl_contains(entry.tables.list, 'notes'))
  end)
end)
