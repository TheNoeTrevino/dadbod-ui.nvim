-- Specs for schema/table introspection in the drawer (M6): folding parsed
-- results into the entry, honoring hide_schemas, rendering the Schemas/Tables
-- sections, schema-support detection, and a guarded end-to-end sqlite expand.

local ids = require('dadbod-ui.drawer.ids')
local notifications = require('dadbod-ui.notifications')
local h = require('helper')

describe('schema introspection: apply_schemas', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('folds schemas and (schema, table) rows into the entry', function()
    d = h.make_drawer({ g_dbs = { dev = 'postgres://h/dev' }, connector = 'offline' })
    local entry = h.entry_named(d, 'dev')
    d:introspect():apply_schemas(entry, { 'public', 'app' }, {
      { 'public', 'users' },
      { 'public', 'posts' },
      { 'app', 'tasks' },
    })
    assert.same({ 'public', 'app' }, entry.schemas.list)
    assert.same({ 'posts', 'users' }, entry.schemas.items.public) -- sorted
    assert.same({ 'tasks' }, entry.schemas.items.app)
    -- the flat table list collects every schema's tables
    assert.equals(3, #entry.tables)
  end)

  it('drops schemas and tables matching hide_schemas', function()
    d = h.make_drawer({
      g_dbs = { dev = 'postgres://h/dev' },
      connector = 'offline',
      config = { hide_schemas = { 'information_schema', 'pg_' } },
    })
    local entry = h.entry_named(d, 'dev')
    d:introspect():apply_schemas(entry, { 'public', 'information_schema', 'pg_catalog' }, {
      { 'public', 'users' },
      { 'information_schema', 'tables' },
      { 'pg_catalog', 'pg_class' },
    })
    assert.same({ 'public' }, entry.schemas.list)
    assert.same({ 'users' }, entry.tables)
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
    d = h.make_drawer({ g_dbs = { dev = 'postgres://h/dev' }, connector = 'offline' })
    d:open()
    local entry = h.entry_named(d, 'dev')
    d:set_expanded(ids.db(entry.key_name), true)
    d:set_expanded(ids.section(entry.key_name, 'schemas'), true)
    d:set_expanded(ids.schema(entry.key_name, 'public'), true)
    d:set_expanded(ids.table(entry.key_name, 'public', 'users'), true)
    entry.schemas.list = { 'public' }
    entry.schemas.items = { public = { 'users' } }
    d:render()
    local l = h.buf_lines(d.bufnr)
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
    d = h.make_drawer({ g_dbs = { qa = 'sqlite:/tmp/whatever.db' }, connector = 'offline' })
    d:open()
    local entry = h.entry_named(d, 'qa')
    assert.is_false(entry.schema_support)
    d:set_expanded(ids.db(entry.key_name), true)
    d:set_expanded(ids.section(entry.key_name, 'tables'), true)
    entry.tables = { 'contacts' }
    d:render()
    local l = h.buf_lines(d.bufnr)
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

  it('records the connect time on the entry without a popup', function()
    d = h.make_drawer({ g_dbs = { dev = 'postgres://h/dev' }, connector = 'offline' })
    d.connector = function()
      return 'postgres://h/dev'
    end
    d:open()
    local entry = h.entry_named(d, 'dev')
    local before = notifications.get_last_msg()
    d:introspect():connect(entry)
    -- the timing is captured on the entry, and the connect emitted no message
    assert.is_number(entry.connect_ms)
    assert.equals(before, notifications.get_last_msg())
  end)

  it('surfaces the connect time in the details view, not a notification', function()
    d = h.make_drawer({ g_dbs = { dev = 'postgres://h/dev' }, connector = 'offline' })
    d.connector = function()
      return 'postgres://h/dev'
    end
    d:open()
    local entry = h.entry_named(d, 'dev')
    d:introspect():connect(entry)
    d.show_details = true
    d:render()
    -- e.g. "▾ dev ✓ (postgres - g:dbs - 3ms)"
    assert.is_truthy(h.buf_lines(d.bufnr)[1]:match('%- %d+ms%)$'))
  end)
end)

describe('schema introspection: sqlite end-to-end (guarded)', function()
  local d, url
  before_each(function()
    url = h.sqlite_db('CREATE TABLE contacts(id INTEGER, name TEXT); CREATE TABLE notes(id INTEGER);')
  end)
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('connects and lists real tables directly under the connection', function()
    if not url then
      return pending('sqlite3 not installed')
    end
    d = h.make_drawer({ g_dbs = { qa = url }, connector = 'offline' })
    d.connector = require('dadbod-ui.bridge').connect -- real connect for sqlite (offline)
    d:open()
    local entry = h.entry_named(d, 'qa')
    d:introspect():connect(entry)
    assert.is_truthy(entry.conn ~= nil and entry.conn ~= '')
    d:introspect():populate_tables(entry)
    assert.is_true(vim.tbl_contains(entry.tables, 'contacts'))
    assert.is_true(vim.tbl_contains(entry.tables, 'notes'))
  end)
end)
