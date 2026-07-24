-- Specs for table "Script As" (issue #90): the drawer's table -> "Script As"
-- subtree and its dispatch into the generic script_as orchestrator. Adapter
-- action sets (queries, parsers, builders) get their own describes as each
-- engine lands. All pure or mock-driven -- no live database.

local schemas = require('dadbod-ui.schemas')
local drawer_mod = require('dadbod-ui.drawer')
local ids = require('dadbod-ui.drawer.ids')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')
local script_as = require('dadbod-ui.script_as')

-- A drawer over an instance seeded with injected connections (offline connector).
-- `make_drawer`/`entry_named`/`lines` follow the per-spec convention (see
-- routine_scripts_spec.lua); there is no shared test-helper module for them.
local function make_drawer(g_dbs, overrides)
  local cfg = config.resolve(
    vim.tbl_extend(
      'force',
      { save_location = '/tmp/dbui_tbl_scripts', drawer = { show_help = false } },
      overrides or {}
    )
  )
  local instance = state.new(cfg):populate({ env = {}, g_dbs = g_dbs, file_entries = {} })
  local d = drawer_mod.new(instance)
  d.connector = function(url)
    return url
  end
  return d
end

local function caps(scheme)
  return schemas.get(scheme).table_scripts
end

--- The action whose menu label is `label` on `scheme` (order-independent lookup).
local function action(scheme, label)
  for _, a in ipairs(caps(scheme).actions) do
    if a.label == label then
      return a
    end
  end
end

--- Build the DDL for `scheme`'s `label` action from a context (applying the
--- generic `build` default for query-only actions that define none).
local function build(scheme, label, ctx)
  local act = action(scheme, label)
  return (act.build or script_as.fetched)(ctx)
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

--- Whether any rendered drawer line contains `text` (plain substring).
local function has_line(d, text)
  return vim.iter(lines(d)):any(function(l)
    return l:find(text, 1, true)
  end)
end

--- The first rendered node whose label is exactly `label`.
local function node_labeled(d, label)
  return vim.iter(d.content):find(function(node)
    return node.label == label
  end)
end

describe('table_scripts: capability presence + action set', function()
  it('postgres exposes table_scripts; unported adapters do not', function()
    for _, scheme in ipairs({ 'sqlite', 'oracle', 'clickhouse', 'bigquery', 'mongodb' }) do
      assert.is_nil(caps(scheme), scheme .. ' has no table_scripts')
    end
    local labels = vim.tbl_map(function(a)
      return a.label
    end, caps('postgres').actions)
    assert.same({ 'DROP To', 'SELECT To', 'INSERT To', 'UPDATE To', 'DELETE To' }, labels)
  end)
end)

describe('table_scripts: postgres queries (built server-side)', function()
  it('SELECT To aggregates quoted column names over the live attributes', function()
    local sql = action('postgres', 'SELECT To').query('public', 'users')
    assert.is_truthy(sql:find('string_agg(quote_ident(a.attname)', 1, true))
    assert.is_truthy(sql:find('NOT a.attisdropped', 1, true))
    assert.is_truthy(sql:find("n.nspname = 'public' AND c.relname = 'users'", 1, true))
  end)

  it('INSERT To binds each column with its type, excluding identity/generated', function()
    local sql = action('postgres', 'INSERT To').query('public', 'users')
    assert.is_truthy(sql:find('format_type(a.atttypid, a.atttypmod)', 1, true))
    assert.is_truthy(sql:find("a.attidentity = '' AND a.attgenerated = ''", 1, true))
  end)

  it('UPDATE To sets non-key columns and keys the WHERE on the primary key', function()
    local sql = action('postgres', 'UPDATE To').query('public', 'users')
    assert.is_truthy(sql:find('FILTER (WHERE NOT pk.is_pk', 1, true))
    assert.is_truthy(sql:find('FILTER (WHERE pk.is_pk)', 1, true))
    assert.is_truthy(sql:find('i.indisprimary AND a.attnum = ANY(i.indkey)', 1, true))
    assert.is_truthy(sql:find('no primary key', 1, true)) -- PK-less fallback
  end)

  it('DELETE To keys the WHERE on the primary key with the same fallback', function()
    local sql = action('postgres', 'DELETE To').query('public', 'users')
    assert.is_truthy(sql:find("'DELETE FROM '", 1, true))
    assert.is_truthy(sql:find('FILTER (WHERE pk.is_pk)', 1, true))
  end)

  it('quotes embedded in identifiers stay inside the literals', function()
    local sql = action('postgres', 'SELECT To').query('pub', "we'ird")
    assert.is_truthy(sql:find("c.relname = 'we''ird'", 1, true))
  end)
end)

describe('table_scripts: postgres builders', function()
  it('DROP To builds a quoted DROP TABLE from the names alone', function()
    assert.equals(
      'DROP TABLE "public"."users";',
      build('postgres', 'DROP To', { schema = 'public', name = 'users', kind = 'table' })
    )
    assert.equals(
      'DROP TABLE "pu""b"."t";',
      build('postgres', 'DROP To', { schema = 'pu"b', name = 't', kind = 'table' })
    )
  end)
end)

describe('table_scripts: mysql columns fetch + builders', function()
  -- Synthetic `-N` TSV rows of the columns query: an auto-increment pk, two
  -- plain columns (one with mysql 8's DEFAULT_GENERATED expression-default
  -- marker, which must stay insertable), and a stored generated column.
  local rows = {
    'id\tint\tPRI\tauto_increment',
    'email\tvarchar(80)\tUNI\t',
    'created_at\ttimestamp\t\tDEFAULT_GENERATED',
    'slug\tvarchar(80)\t\tSTORED GENERATED',
  }

  local function cols()
    return action('mysql', 'SELECT To').parse(rows)
  end

  it('the columns query scopes to the schema, or DATABASE() when flat', function()
    local sql = action('mysql', 'SELECT To').query('shop', 'users')
    assert.is_truthy(sql:find("table_schema = 'shop' AND table_name = 'users'", 1, true))
    local flat = action('mysql', 'SELECT To').query('', 'users')
    assert.is_truthy(flat:find('table_schema = DATABASE()', 1, true))
    assert.is_nil(action('mysql', 'SELECT To').args) -- keeps the adapter's stdin + -N framing
  end)

  it('parse splits TSV rows into name/type/pk/generated', function()
    local parsed = cols()
    assert.equals(4, #parsed)
    assert.same({ name = 'id', type = 'int', pk = true, generated = true }, parsed[1])
    assert.same({ name = 'created_at', type = 'timestamp', pk = false, generated = false }, parsed[3])
    assert.same({ name = 'slug', type = 'varchar(80)', pk = false, generated = true }, parsed[4])
  end)

  it('SELECT To lists every column from the qualified table', function()
    assert.equals(
      'SELECT `id`\n     , `email`\n     , `created_at`\n     , `slug`\nFROM `shop`.`users`;',
      build('mysql', 'SELECT To', { schema = 'shop', name = 'users', kind = 'table', data = cols() })
    )
  end)

  it('INSERT To binds writable columns only (no auto-increment, no generated)', function()
    assert.equals(
      'INSERT INTO `users` (\n    `email`\n  , `created_at`\n) VALUES (\n'
        .. '    :email  -- varchar(80)\n  , :created_at  -- timestamp\n);',
      build('mysql', 'INSERT To', { schema = '', name = 'users', kind = 'table', data = cols() })
    )
  end)

  it('UPDATE To sets writable non-key columns and keys the WHERE on the pk', function()
    assert.equals(
      'UPDATE `shop`.`users`\nSET `email` = :email  -- varchar(80)\n'
        .. '  , `created_at` = :created_at  -- timestamp\nWHERE `id` = :id;',
      build('mysql', 'UPDATE To', { schema = 'shop', name = 'users', kind = 'table', data = cols() })
    )
  end)

  it('DELETE To falls back to the placeholder condition without a pk', function()
    local nopk = action('mysql', 'SELECT To').parse({ 'msg\ttext\t\t' })
    assert.equals(
      'DELETE FROM `logs`\nWHERE <condition>  /* no primary key */;',
      build('mysql', 'DELETE To', { schema = '', name = 'logs', kind = 'table', data = nopk })
    )
  end)

  it('DROP To builds from the names alone; an empty fetch yields nil', function()
    assert.equals('DROP TABLE `shop`.`users`;', build('mysql', 'DROP To', { schema = 'shop', name = 'users' }))
    assert.equals('DROP TABLE `a``b`;', build('mysql', 'DROP To', { schema = '', name = 'a`b' }))
    assert.is_nil(build('mysql', 'SELECT To', { schema = '', name = 'ghost', data = {} }))
  end)

  it('mariadb inherits the mysql capability unchanged', function()
    assert.equals(caps('mysql'), caps('mariadb'))
  end)
end)

describe('table_scripts: mysql CREATE To (SHOW CREATE TABLE)', function()
  it('asks the server for the rendered DDL, keeping the stdin + -N framing', function()
    local act = action('mysql', 'CREATE To')
    assert.equals('SHOW CREATE TABLE `shop`.`users`', act.query('shop', 'users'))
    assert.equals('SHOW CREATE TABLE `users`', act.query('', 'users'))
    assert.is_nil(act.args)
    assert.is_nil(act.build) -- the parse IS the script
  end)

  it('parse drops the name cell and unescapes the batch encoding', function()
    -- one batch row: `name<TAB>ddl` with two-char \n escapes, including a
    -- literal backslash-n in a comment that must NOT become a newline
    local row = "users\tCREATE TABLE `users` (\\n  `bio` text COMMENT 'a\\\\nb'\\n)"
    assert.equals(
      "CREATE TABLE `users` (\n  `bio` text COMMENT 'a\\nb'\n);",
      action('mysql', 'CREATE To').parse({ row })
    )
  end)

  it('parse yields nil on empty output (unknown table -> could not script)', function()
    assert.is_nil(action('mysql', 'CREATE To').parse({ '' }))
  end)
end)

describe('table_scripts: sqlserver columns fetch + builders', function()
  -- Synthetic pipe-separated rows of the columns query: an identity pk, two
  -- plain columns, a computed column and a rowversion stamp.
  local rows = {
    'id|int|1|0|0|1',
    'email|nvarchar(80)|0|0|0|0',
    'total|decimal(10,2)|0|0|0|0',
    'slug|nvarchar(80)|0|1|0|0',
    'stamp|rowversion|0|0|1|0',
  }

  local function cols()
    return action('sqlserver', 'SELECT To').parse(rows)
  end

  it('the columns query resolves via a bracket-quoted OBJECT_ID', function()
    local sql = action('sqlserver', 'SELECT To').query('dbo', 'my]t', 'table')
    assert.is_truthy(sql:find("OBJECT_ID('[dbo].[my]]t]')", 1, true))
    assert.is_truthy(sql:find("COLUMNPROPERTY(c.object_id, c.name, 'charmaxlen')", 1, true))
    assert.is_nil(action('sqlserver', 'SELECT To').args) -- keeps the pipe-separated framing
  end)

  it('parse splits pipe rows into name/type/pk/generated', function()
    local parsed = cols()
    assert.equals(5, #parsed)
    assert.same({ name = 'id', type = 'int', pk = true, generated = true }, parsed[1])
    assert.same({ name = 'total', type = 'decimal(10,2)', pk = false, generated = false }, parsed[3])
    assert.same({ name = 'stamp', type = 'rowversion', pk = false, generated = true }, parsed[5])
  end)

  it('SELECT To lists every column from the qualified table', function()
    assert.equals(
      'SELECT [id]\n     , [email]\n     , [total]\n     , [slug]\n     , [stamp]\nFROM [dbo].[users];',
      build('sqlserver', 'SELECT To', { schema = 'dbo', name = 'users', kind = 'table', data = cols() })
    )
  end)

  it('INSERT To binds writable columns only (no identity/computed/rowversion)', function()
    assert.equals(
      'INSERT INTO [dbo].[users] (\n    [email]\n  , [total]\n) VALUES (\n'
        .. '    :email  -- nvarchar(80)\n  , :total  -- decimal(10,2)\n);',
      build('sqlserver', 'INSERT To', { schema = 'dbo', name = 'users', kind = 'table', data = cols() })
    )
  end)

  it('UPDATE To sets writable non-key columns and keys the WHERE on the pk', function()
    assert.equals(
      'UPDATE [dbo].[users]\nSET [email] = :email  -- nvarchar(80)\n'
        .. '  , [total] = :total  -- decimal(10,2)\nWHERE [id] = :id;',
      build('sqlserver', 'UPDATE To', { schema = 'dbo', name = 'users', kind = 'table', data = cols() })
    )
  end)

  it('DELETE To falls back to the placeholder condition without a pk', function()
    local nopk = action('sqlserver', 'SELECT To').parse({ 'msg|text|0|0|0|0' })
    assert.equals(
      'DELETE FROM [dbo].[logs]\nWHERE <condition>  /* no primary key */;',
      build('sqlserver', 'DELETE To', { schema = 'dbo', name = 'logs', kind = 'table', data = nopk })
    )
  end)

  it('DROP To builds from the names alone; an empty fetch yields nil', function()
    assert.equals('DROP TABLE [dbo].[users];', build('sqlserver', 'DROP To', { schema = 'dbo', name = 'users' }))
    assert.is_nil(build('sqlserver', 'SELECT To', { schema = 'dbo', name = 'ghost', data = {} }))
  end)
end)

describe('table_scripts: produce orchestration', function()
  local bridge = require('dadbod-ui.bridge')
  local real_run_many = bridge.run_many
  local d
  after_each(function()
    bridge.run_many = real_run_many
    if d then
      d:close()
      d = nil
    end
  end)

  it('query-less DROP builds synchronously; query actions pass server text through', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    local entry = entry_named(d, 'dev')
    local called = 0
    bridge.run_many = function()
      called = called + 1
    end
    local got
    script_as.produce(
      { entry = entry, schema = 'public', name = 'users', kind = 'table', action = action('postgres', 'DROP To') },
      function(text)
        got = text
      end
    )
    assert.equals(0, called) -- never touched the database
    assert.equals('DROP TABLE "public"."users";', got)

    entry.conn = entry.url -- pretend connected
    bridge.run_many = function(_specs, on_done)
      on_done({ { code = 0, stdout = 'SELECT id\nFROM public.users;\n', stderr = '' } })
    end
    script_as.produce(
      { entry = entry, schema = 'public', name = 'users', kind = 'table', action = action('postgres', 'SELECT To') },
      function(text)
        got = text
      end
    )
    assert.equals('SELECT id\nFROM public.users;', got)
  end)
end)

describe('table_scripts: drawer rendering', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  --- Seed one `users` table under `public` and expand down into it, with an
  --- injected capability (adapters grow their real `table_scripts` in later
  --- commits; the drawer only cares that the entry carries one).
  local function render_table(capability)
    d = make_drawer({ dev = 'postgres://h/dev' })
    d:open()
    local entry = entry_named(d, 'dev')
    entry.table_scripts = capability
    entry.schemas.list = { 'public' }
    entry.schemas.items = { public = { 'users' } }
    d:set_expanded(ids.db(entry.key_name), true)
    d:set_expanded(ids.section(entry.key_name, 'schemas'), true)
    d:set_expanded(ids.schema(entry.key_name, 'public'), true)
    d:set_expanded(ids.table(entry.key_name, 'public', 'users'), true)
    return entry
  end

  it('a table with the capability expands to Script As ahead of its helpers', function()
    local entry = render_table({ actions = { { label = 'FAKE To' } } })
    d:set_expanded(ids.table_script_as(entry.key_name, 'public', 'users'), true)
    d:render()
    assert.is_truthy(has_line(d, 'Script As'))
    assert.is_truthy(has_line(d, 'FAKE To'))
    -- pinned first: the submenu leads the (user-orderable) helper leaves
    local script_node = node_labeled(d, 'Script As')
    local list_node = node_labeled(d, 'List')
    assert.is_truthy(script_node.index < list_node.index)
  end)

  it('without the capability a table lists only its helpers', function()
    render_table(nil)
    d:render()
    assert.is_truthy(has_line(d, 'List'))
    assert.is_falsy(has_line(d, 'Script As'))
  end)

  it("an action leaf's on_activate dispatches to script_as.run with kind 'table'", function()
    local entry = render_table({ actions = { { label = 'FAKE To' } } })
    d:set_expanded(ids.table_script_as(entry.key_name, 'public', 'users'), true)
    d:render()
    local real_run = script_as.run
    local got
    script_as.run = function(opts)
      got = opts
    end
    local ok, err = pcall(function()
      node_labeled(d, 'FAKE To').on_activate()
    end)
    script_as.run = real_run
    assert.is_truthy(ok, err)
    assert.equals('table', got.kind)
    assert.equals('users', got.name)
    assert.equals('public', got.schema)
    assert.equals(entry, got.entry)
    assert.equals('FAKE To', got.action.label)
  end)
end)
