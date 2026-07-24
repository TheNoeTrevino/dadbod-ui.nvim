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
