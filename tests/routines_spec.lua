-- Specs for stored-procedure / function introspection (issue #24): the per-adapter
-- catalog SQL + definition builders, folding parsed routine rows into the entry
-- (nested per schema / flat / hidden schemas), the Procedures drawer section
-- (nested, flat, non-empty-only, sqlite no-op), and the open-definition action.
-- Covers listing stored routines (procedures/functions) per adapter.
-- No live DB required -- parsers are pure and populate mocks bridge.run_many.

local schemas = require('dadbod-ui.schemas')
local drawer_mod = require('dadbod-ui.drawer')
local ids = require('dadbod-ui.drawer.ids')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')

-- A drawer over an instance seeded with injected connections; connector echoes
-- the url so entries "connect" offline.
local function make_drawer(g_dbs, overrides)
  local cfg = config.resolve(
    vim.tbl_extend('force', { save_location = '/tmp/dbui_routines', drawer = { show_help = false } }, overrides or {})
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

local function lines(d)
  return vim.api.nvim_buf_get_lines(d.bufnr, 0, -1, false)
end

describe('routines: adapter metadata', function()
  it('exposes procedures_query + routine_definition for postgres and mysql', function()
    for _, scheme in ipairs({ 'postgres', 'mysql', 'mariadb', 'sqlserver', 'oracle' }) do
      local s = schemas.get(scheme)
      assert.is_string(s.procedures_query, scheme .. ' has procedures_query')
      assert.is_function(s.routine_definition, scheme .. ' has routine_definition')
    end
  end)

  it('has no routine support for sqlite (no stored procedures)', function()
    local s = schemas.get('sqlite')
    assert.is_nil(s.procedures_query)
    assert.is_nil(s.routine_definition)
  end)

  it('builds a postgres definition query keyed on schema + name, escaping quotes', function()
    local sql = schemas.get('postgres').routine_definition("pu'blic", "o'reilly", 'function')
    assert.is_truthy(sql:match('pg_get_functiondef'))
    -- single quotes are doubled so a quote in the name stays inside the literal
    assert.is_truthy(sql:find("nspname = 'pu''blic'", 1, true))
    assert.is_truthy(sql:find("proname = 'o''reilly'", 1, true))
  end)

  it('builds a mysql SHOW CREATE keyed on kind, escaping backticks', function()
    local my = schemas.get('mysql')
    assert.equals('SHOW CREATE PROCEDURE `app`.`do_thing`', my.routine_definition('app', 'do_thing', 'procedure'))
    assert.equals('SHOW CREATE FUNCTION `app`.`calc`', my.routine_definition('app', 'calc', 'function'))
    -- backticks in an identifier are doubled
    assert.is_truthy(my.routine_definition('a`b', 'c', 'procedure'):find('`a``b`', 1, true))
  end)

  it('builds a bracket-quoted sqlserver OBJECT_ID so a dotted/spaced name still resolves', function()
    -- regression: OBJECT_ID('schema.name') built without brackets returns NULL
    -- (a NULL definition) for a schema/routine containing a space or a dot.
    local ss = schemas.get('sqlserver')
    assert.equals(
      "SELECT OBJECT_DEFINITION(OBJECT_ID('[dbo].[do_thing]'))",
      ss.routine_definition('dbo', 'do_thing', 'procedure')
    )
    -- a ']' inside a part is doubled to stay a valid bracket identifier
    assert.is_truthy(ss.routine_definition('my schema', 'a]b', 'function'):find('[my schema].[a]]b]', 1, true))
    -- a "'" is still escaped for the outer single-quoted string literal
    assert.is_truthy(ss.routine_definition("o'reilly", 'x', 'procedure'):find("o''reilly", 1, true))
  end)

  it('scopes mysql routines to the connected database on the tables-only path', function()
    -- regression: the tables-only path (mysql url naming a database) used the
    -- global procedures_query and so listed routines from EVERY schema on the
    -- server, flattening them all into this one db's Procedures node.
    local my = schemas.get('mysql')
    assert.is_string(my.tables_procedures_query)
    assert.is_truthy(my.tables_procedures_query:find('routine_schema = DATABASE()', 1, true))
  end)
end)

describe('routines: result parsing', function()
  it('parses postgres (schema, name, kind) rows via parse_results min_len 3', function()
    local pg = schemas.get('postgres')
    local out = pg.parse_results({
      'public|do_thing|procedure',
      'public|calc|function',
      '',
    }, 3)
    assert.same({ 'public', 'do_thing', 'procedure' }, out[1])
    assert.same({ 'public', 'calc', 'function' }, out[2])
    assert.equals(2, #out)
  end)

  it('parses mysql tab-delimited routine rows', function()
    local my = schemas.get('mysql')
    local out = my.parse_results({
      'app\tdo_thing\tprocedure',
    }, 3)
    assert.same({ 'app', 'do_thing', 'procedure' }, out[1])
  end)
end)

describe('routines: apply_routines', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('groups routines per schema for a schema adapter, honoring hide_schemas', function()
    d = make_drawer({ dev = 'postgres://h/dev' }, { hide_schemas = { 'pg_' } })
    local entry = entry_named(d, 'dev')
    local scheme_info = schemas.get(entry.scheme, d.config)
    d:introspect():apply_routines(entry, scheme_info, {
      { 'public', 'do_thing', 'procedure' },
      { 'public', 'calc', 'function' },
      { 'app', 'run', 'procedure' },
      { 'pg_catalog', 'internal', 'function' },
    })
    assert.same({ 'public', 'app' }, entry.routines.list)
    assert.equals(2, #entry.routines.items.public)
    assert.equals('do_thing', entry.routines.items.public[1].name)
    assert.equals('procedure', entry.routines.items.public[1].kind)
    -- the pre-built definition query rides on the item (drives the open action)
    assert.is_truthy(entry.routines.items.public[1].content:match('pg_get_functiondef'))
    -- hidden schema dropped
    assert.is_nil(entry.routines.items.pg_catalog)
  end)

  it('collects routines flat for a non-schema adapter (mysql-with-db)', function()
    d = make_drawer({ app = 'mysql://h/app' })
    local entry = entry_named(d, 'app')
    assert.is_false(entry.schema_support)
    assert.is_true(entry.routine_support)
    local scheme_info = schemas.get(entry.scheme, d.config)
    d:introspect():apply_routines(entry, scheme_info, {
      { 'app', 'do_thing', 'procedure' },
      { 'app', 'calc', 'function' },
    })
    assert.equals(2, #entry.routines.flat)
    assert.equals('do_thing', entry.routines.flat[1].name)
    assert.is_truthy(entry.routines.flat[1].content:find('SHOW CREATE PROCEDURE', 1, true))
  end)

  it('prunes emptied schemas across a refresh; drawer expand state is untouched', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    local entry = entry_named(d, 'dev')
    local scheme_info = schemas.get(entry.scheme, d.config)
    d:introspect():apply_routines(entry, scheme_info, {
      { 'public', 'a', 'procedure' },
      { 'app', 'b', 'function' },
    })
    -- Expand state lives in the drawer's map (keyed by stable ids), so a
    -- refresh that rebuilds the domain containers cannot lose it.
    d:set_expanded(ids.routine_schema(entry.key_name, 'public'), true)
    -- a refresh where `app` no longer has routines
    d:introspect():apply_routines(entry, scheme_info, { { 'public', 'a', 'procedure' } })
    assert.is_true(d:is_expanded(ids.routine_schema(entry.key_name, 'public')))
    assert.is_nil(entry.routines.items.app)
    assert.same({ 'public' }, entry.routines.list)
  end)
end)

describe('routines: concurrent populate', function()
  local d
  local bridge = require('dadbod-ui.bridge')
  local real_run_many = bridge.run_many
  after_each(function()
    bridge.run_many = real_run_many
    if d then
      d:close()
      d = nil
    end
  end)

  local function completed(stdout)
    return { code = 0, stdout = stdout, stderr = '' }
  end

  it('uses the database-scoped routines query on the tables-only path (mysql-with-db)', function()
    -- regression: populate_tables used the global procedures_query, leaking
    -- routines from every schema into this one db's Procedures node.
    d = make_drawer({ app = 'mysql://h/app' })
    local entry = entry_named(d, 'app')
    entry.conn = 'mysql://h/app' -- pretend connected
    local seen_query
    bridge.run_many = function(specs, on_done)
      assert.equals(1, #specs)
      seen_query = specs[1].stdin -- mysql feeds the query on stdin
      on_done({ completed('app\tdo_thing\tprocedure\n') })
    end
    local real_adapter_call = bridge.adapter_call
    bridge.adapter_call = function()
      return {}
    end
    d:introspect():populate_tables(entry)
    bridge.adapter_call = real_adapter_call
    local my = schemas.get('mysql')
    assert.equals(my.tables_procedures_query, seen_query)
    assert.equals(1, #entry.routines.flat)
  end)

  it('fans schemas + tables + routines out together and folds them in', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    local entry = entry_named(d, 'dev')
    entry.conn = 'postgres://h/dev' -- pretend connected
    -- Mock the fan-out: three specs in, three aligned results back.
    bridge.run_many = function(specs, on_done)
      assert.equals(3, #specs) -- schemas + tables + routines, one round-trip
      on_done({
        completed('public\n'),
        completed('public|users\n'),
        completed('public|do_thing|procedure\n'),
      })
    end
    d:introspect():populate_schemas(entry)
    assert.same({ 'public' }, entry.schemas.list)
    assert.same({ 'users' }, entry.schemas.items.public)
    assert.same({ 'public' }, entry.routines.list)
    assert.equals('do_thing', entry.routines.items.public[1].name)
  end)
end)

describe('routines: drawer rendering', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('renders Procedures -> schema -> routine for a schema adapter', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    d:open()
    local entry = entry_named(d, 'dev')
    d:set_expanded(ids.db(entry.key_name), true)
    d:set_expanded(ids.section(entry.key_name, 'routines'), true)
    d:set_expanded(ids.routine_schema(entry.key_name, 'public'), true)
    entry.routines.list = { 'public' }
    entry.routines.items = {
      public = {
        { name = 'do_thing', kind = 'procedure', content = 'x' },
        { name = 'calc', kind = 'function', content = 'y' },
      },
    }
    d:render()
    local l = lines(d)
    assert.is_truthy(vim.tbl_contains(l, '  ▾ Procedures (2)'))
    assert.is_truthy(vim.tbl_contains(l, '    ▾ public (2)'))
    assert.is_truthy(vim.tbl_contains(l, '      ƒ do_thing [P]'))
    assert.is_truthy(vim.tbl_contains(l, '      ƒ calc [F]'))
  end)

  it('renders routines flat for a non-schema adapter (mysql-with-db)', function()
    d = make_drawer({ app = 'mysql://h/app' })
    d:open()
    local entry = entry_named(d, 'app')
    d:set_expanded(ids.db(entry.key_name), true)
    d:set_expanded(ids.section(entry.key_name, 'routines'), true)
    entry.routines.flat = { { name = 'run', kind = 'procedure', content = 'z' } }
    d:render()
    local l = lines(d)
    assert.is_truthy(vim.tbl_contains(l, '  ▾ Procedures (1)'))
    assert.is_truthy(vim.tbl_contains(l, '    ƒ run [P]'))
  end)

  it('shows no Procedures node when the connection has zero routines', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    d:open()
    local entry = entry_named(d, 'dev')
    d:set_expanded(ids.db(entry.key_name), true)
    d:render()
    for _, line in ipairs(lines(d)) do
      assert.is_nil(line:match('Procedures'))
    end
  end)

  it('shows no Procedures node for sqlite (no routine support)', function()
    d = make_drawer({ qa = 'sqlite:/tmp/whatever.db' })
    d:open()
    local entry = entry_named(d, 'qa')
    assert.is_false(entry.routine_support)
    d:set_expanded(ids.db(entry.key_name), true)
    -- even if some stray state existed, the section is gated on routine_support
    d:render()
    for _, line in ipairs(lines(d)) do
      assert.is_nil(line:match('Procedures'))
    end
  end)
end)

describe('routines: open definition', function()
  local d
  local query_bufs = {}
  after_each(function()
    for _, b in ipairs(query_bufs) do
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
    query_bufs = {}
    if d then
      d:close()
      d = nil
    end
  end)

  it('opens a routine node into a buffer prefilled with its definition query', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    d:open()
    local entry = entry_named(d, 'dev')
    local content = schemas.get(entry.scheme, d.config).routine_definition('public', 'do_thing', 'procedure')
    d:query():open({
      type = 'routine',
      key_name = entry.key_name,
      table = 'do_thing',
      schema = 'public',
      label = 'do_thing [P]',
      content = content,
    }, 'edit')
    query_bufs[#query_bufs + 1] = vim.api.nvim_get_current_buf()

    local buf_text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
    assert.is_truthy(buf_text:match('pg_get_functiondef'))
    assert.equals(entry.key_name, vim.b.dbui_db_key_name)
    assert.equals('do_thing', vim.b.dbui_table_name)
  end)
end)
