-- Specs for the "Script As" feature (issue #86): the per-action `routine_scripts`
-- capability on the sqlserver adapter (its fetch queries and DDL builders), the
-- generic orchestrator's default text parser and dispatch, the drawer's
-- routine -> "Script As" subtree, and the query controller's write destinations.
-- All pure or mock-driven -- no live database.

local schemas = require('dadbod-ui.schemas')
local drawer_mod = require('dadbod-ui.drawer')
local ids = require('dadbod-ui.drawer.ids')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')
local routine_script = require('dadbod-ui.routine_script')

local function caps(scheme)
  return schemas.get(scheme).routine_scripts
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
  return (act.build or routine_script.fetched)(ctx)
end

-- A drawer over an instance seeded with injected connections (offline connector).
-- `make_drawer`/`entry_named`/`lines` follow the per-spec convention (see
-- routines_spec.lua); there is no shared test-helper module for them.
local function make_drawer(g_dbs, overrides)
  local cfg = config.resolve(
    vim.tbl_extend('force', { save_location = '/tmp/dbui_scripts', drawer = { show_help = false } }, overrides or {})
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

--- Whether any rendered drawer line contains `text` (plain substring).
local function has_line(d, text)
  return vim.iter(lines(d)):any(function(l)
    return l:find(text, 1, true)
  end)
end

describe('routine_scripts: capability presence + action set', function()
  it('sqlserver exposes routine_scripts; other adapters do not', function()
    assert.is_table(caps('sqlserver'))
    for _, scheme in ipairs({ 'postgres', 'oracle', 'mysql', 'sqlite' }) do
      assert.is_nil(caps(scheme), scheme .. ' has no routine_scripts')
    end
  end)

  it('offers the SSMS action set', function()
    local function labels(scheme)
      return vim.tbl_map(function(a)
        return a.label
      end, caps(scheme).actions)
    end
    assert.same(
      { 'CREATE To', 'ALTER To', 'CREATE OR ALTER To', 'DROP To', 'DROP And CREATE To', 'EXECUTE To' },
      labels('sqlserver')
    )
  end)
end)

describe('routine_scripts: sqlserver queries', function()
  it('CREATE To fetches the stored source from sys.sql_modules by bracket-quoted OBJECT_ID', function()
    local sql = action('sqlserver', 'CREATE To').query('dbo', 'do_thing')
    assert.is_truthy(sql:find('SET NOCOUNT ON', 1, true))
    assert.is_truthy(sql:find('FROM sys.sql_modules', 1, true))
    assert.is_truthy(sql:find("OBJECT_ID('[dbo].[do_thing]')", 1, true))
    -- an encrypted module (NULL definition) yields no rows -> a clean error
    assert.is_truthy(sql:find('definition IS NOT NULL', 1, true))
    -- a ']' in a part is doubled; a "'" is escaped for the outer literal
    assert.is_truthy(action('sqlserver', 'CREATE To').query('my schema', 'a]b'):find('[my schema].[a]]b]', 1, true))
    assert.is_truthy(action('sqlserver', 'CREATE To').query("o'reilly", 'x'):find("o''reilly", 1, true))
  end)

  it('definition fetches carry the raw untruncated -y 0 args; the parameter fetch does not', function()
    for _, label in ipairs({ 'CREATE To', 'ALTER To', 'CREATE OR ALTER To', 'DROP And CREATE To' }) do
      assert.same({ '-y', '0', '-Q' }, action('sqlserver', label).args, label)
    end
    -- EXECUTE To's parse needs the adapter's pipe-separated formatting
    assert.is_nil(action('sqlserver', 'EXECUTE To').args)
  end)

  it('EXECUTE To fetches parameters over sys.parameters by OBJECT_ID', function()
    local sql = action('sqlserver', 'EXECUTE To').query('dbo', 'do_thing')
    assert.is_truthy(sql:find('sys.parameters', 1, true))
    assert.is_truthy(sql:find("OBJECT_ID('[dbo].[do_thing]')", 1, true))
    assert.is_truthy(sql:find('p.parameter_id > 0', 1, true))
  end)

  it('DROP To needs no query (built from name/kind alone)', function()
    assert.is_nil(action('sqlserver', 'DROP To').query)
  end)
end)

describe('routine_scripts: default text parser', function()
  it('reassembles output lines, trimming blank framing top and bottom', function()
    assert.equals(
      'CREATE PROCEDURE [dbo].[p]\nAS\nSELECT 1',
      routine_script.text({ '', 'CREATE PROCEDURE [dbo].[p]', 'AS', 'SELECT 1', '', '' })
    )
    assert.equals('', routine_script.text({ '', '' }))
  end)

  it('sqlserver EXECUTE To parses (name, type) parameter rows, skipping blanks', function()
    local params = action('sqlserver', 'EXECUTE To').parse({ '@id|int', '@name|varchar', '' })
    assert.same({ { name = '@id', type = 'int' }, { name = '@name', type = 'varchar' } }, params)
  end)
end)

describe('routine_scripts: sqlserver builders', function()
  local proc = { schema = 'dbo', name = 'do_thing', kind = 'procedure' }
  local def = 'CREATE PROCEDURE [dbo].[do_thing]\nAS\nSELECT 1'

  --- `proc` plus fetched `data` (defaults to `def`), the ctx a query-backed build gets.
  local function with_data(source)
    return vim.tbl_extend('force', proc, { data = source or def })
  end

  it('CREATE To returns the fetched definition verbatim', function()
    assert.equals(def, build('sqlserver', 'CREATE To', with_data()))
  end)

  it('ALTER To swaps the leading CREATE for ALTER (first only, case-insensitively)', function()
    assert.equals('ALTER PROCEDURE [dbo].[do_thing]\nAS\nSELECT 1', build('sqlserver', 'ALTER To', with_data()))
    -- lowercase header is matched too, and a later CREATE (e.g. #temp) is untouched
    assert.equals(
      'ALTER proc x as CREATE TABLE #t(i int)',
      build('sqlserver', 'ALTER To', with_data('create proc x as CREATE TABLE #t(i int)'))
    )
  end)

  it('CREATE OR ALTER To prepends OR ALTER to the header', function()
    assert.equals(
      'CREATE OR ALTER PROCEDURE [dbo].[do_thing]\nAS\nSELECT 1',
      build('sqlserver', 'CREATE OR ALTER To', with_data())
    )
  end)

  it('DROP To emits DROP PROCEDURE / DROP FUNCTION by kind', function()
    assert.equals('DROP PROCEDURE [dbo].[do_thing]', build('sqlserver', 'DROP To', proc))
    assert.equals(
      'DROP FUNCTION [dbo].[calc]',
      build('sqlserver', 'DROP To', { schema = 'dbo', name = 'calc', kind = 'function' })
    )
  end)

  it('DROP And CREATE To joins DROP + GO + the definition', function()
    assert.equals('DROP PROCEDURE [dbo].[do_thing]\nGO\n' .. def, build('sqlserver', 'DROP And CREATE To', with_data()))
  end)

  it('EXECUTE To builds an EXEC stub with :name bind placeholders per parameter', function()
    local out = build('sqlserver', 'EXECUTE To', {
      schema = 'dbo',
      name = 'do_thing',
      kind = 'procedure',
      data = { { name = '@id', type = 'int' }, { name = '@name', type = 'varchar' } },
    })
    assert.equals('EXEC [dbo].[do_thing]\n    @id = :id, -- int\n    @name = :name -- varchar', out)
  end)

  it('EXECUTE To is a bare EXEC for a no-parameter procedure', function()
    assert.equals(
      'EXEC [dbo].[do_thing]',
      build('sqlserver', 'EXECUTE To', { schema = 'dbo', name = 'do_thing', kind = 'procedure', data = {} })
    )
  end)

  it('EXECUTE To builds a SELECT call stub with bind placeholders for a function', function()
    assert.equals(
      'SELECT [dbo].[calc](:x /* int */)',
      build('sqlserver', 'EXECUTE To', {
        schema = 'dbo',
        name = 'calc',
        kind = 'function',
        data = { { name = '@x', type = 'int' } },
      })
    )
  end)
end)

describe('routine_scripts: produce orchestration', function()
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

  --- Run `act` against a routine and return what `produce` hands its callback.
  local function produced(entry, schema, name, kind, act)
    local got
    routine_script.produce({ entry = entry, schema = schema, name = name, kind = kind, action = act }, function(text)
      got = text
    end)
    return got
  end

  --- Stub the async fetch to return `stdout` as a single successful result.
  --- Returns a capture table recording the argv of the last fetch command.
  local function stub_stdout(stdout)
    local seen = {}
    bridge.run_many = function(specs, on_done)
      seen.cmd = specs[1].cmd
      on_done({ { code = 0, stdout = stdout, stderr = '' } })
    end
    return seen
  end

  it('query-less actions (DROP) build synchronously with no DB round-trip', function()
    d = make_drawer({ CaRS = 'sqlserver://h/db' })
    local entry = entry_named(d, 'CaRS')
    local called = 0
    bridge.run_many = function()
      called = called + 1
    end
    local got = produced(entry, 'dbo', 'do_thing', 'procedure', action('sqlserver', 'DROP To'))
    assert.equals(0, called) -- never touched the database
    assert.equals('DROP PROCEDURE [dbo].[do_thing]', got)
  end)

  it('actions with a query fetch, parse, then build (sqlserver ALTER)', function()
    d = make_drawer({ CaRS = 'sqlserver://h/db' })
    local entry = entry_named(d, 'CaRS')
    entry.conn = entry.url -- pretend connected
    stub_stdout('CREATE PROC [dbo].[do_thing] AS SELECT 1\n')
    assert.equals(
      'ALTER PROC [dbo].[do_thing] AS SELECT 1',
      produced(entry, 'dbo', 'do_thing', 'procedure', action('sqlserver', 'ALTER To'))
    )
  end)

  it("an action's args override reaches the fetch command", function()
    d = make_drawer({ CaRS = 'sqlserver://h/db' })
    local entry = entry_named(d, 'CaRS')
    entry.conn = entry.url
    local seen = stub_stdout('CREATE PROC [dbo].[do_thing] AS SELECT 1\n')
    produced(entry, 'dbo', 'do_thing', 'procedure', action('sqlserver', 'CREATE To'))
    -- only threading is asserted here; argv layout is command_spec's own spec
    assert.is_truthy(vim.tbl_contains(seen.cmd, '-y'))
    assert.is_falsy(vim.tbl_contains(seen.cmd, '-h-1'))
  end)
end)

describe('routine_scripts: drawer rendering', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  --- Seed one routine under `schema` and expand down to (but not into) the routine.
  local function render_routine(name, url, schema)
    d = make_drawer({ [name] = url })
    d:open()
    local entry = entry_named(d, name)
    entry.routines.list = { schema }
    entry.routines.items = { [schema] = { { name = 'do_thing', kind = 'procedure', content = 'x' } } }
    d:set_expanded(ids.db(entry.key_name), true)
    d:set_expanded(ids.section(entry.key_name, 'routines'), true)
    d:set_expanded(ids.routine_schema(entry.key_name, schema), true)
    return entry
  end

  it('sqlserver: a routine expands to Script As -> the six SSMS actions', function()
    local entry = render_routine('CaRS', 'sqlserver://h/db', 'dbo')
    d:set_expanded(ids.routine(entry.key_name, 'dbo', 'do_thing'), true)
    d:set_expanded(ids.routine_script_as(entry.key_name, 'dbo', 'do_thing'), true)
    d:render()
    for _, label in ipairs({
      'Script As',
      'CREATE To',
      'ALTER To',
      'CREATE OR ALTER To',
      'DROP To',
      'DROP And CREATE To',
      'EXECUTE To',
    }) do
      assert.is_truthy(has_line(d, label), 'missing drawer line: ' .. label)
    end
  end)

  it('an adapter without routine_scripts (oracle) keeps a plain open leaf', function()
    local entry = render_routine('ora', 'oracle://h/dev', 'HR')
    d:set_expanded(ids.routine(entry.key_name, 'HR', 'do_thing'), true)
    d:render()
    assert.is_truthy(has_line(d, 'do_thing [P]'))
    assert.is_falsy(has_line(d, 'Script As'))
  end)
end)

describe('routine_scripts: write destinations', function()
  local d
  local bufs = {}
  after_each(function()
    for _, b in ipairs(bufs) do
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
    bufs = {}
    if d then
      d:close()
      d = nil
    end
  end)

  local function query_buffers()
    return vim.tbl_filter(function(b)
      local key = vim.api.nvim_buf_is_loaded(b) and vim.b[b].dbui_db_key_name
      return key ~= nil and key ~= '' and key ~= false
    end, vim.api.nvim_list_bufs())
  end

  --- Open a drawer on a (pretend-)connected sqlserver connection; returns its entry.
  local function connected()
    d = make_drawer({ CaRS = 'sqlserver://h/db' })
    d:open()
    local entry = entry_named(d, 'CaRS')
    entry.conn = entry.url
    return entry
  end

  it('new: opens exactly one query buffer filled verbatim, without executing', function()
    local entry = connected()
    local before = #query_buffers()
    d:query():write_script(entry, 'new', 'DROP PROCEDURE [dbo].[p]', { table = 'p', schema = 'dbo' })
    local after = query_buffers()
    bufs = after
    assert.equals(before + 1, #after) -- exactly one new buffer, not a duplicate split
    assert.same(
      { 'DROP PROCEDURE [dbo].[p]' },
      vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
    )
  end)

  it('replace: overwrites the active query buffer contents', function()
    local entry = connected()
    d:query():write_script(entry, 'new', 'SELECT 1', { table = 'p', schema = 'dbo' })
    local buf = vim.api.nvim_get_current_buf()
    bufs = { buf }
    d:query():write_script(entry, 'replace', 'ALTER PROCEDURE [dbo].[p]\nAS\nSELECT 2', { table = 'p', schema = 'dbo' })
    assert.same({ 'ALTER PROCEDURE [dbo].[p]', 'AS', 'SELECT 2' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.equals(1, #query_buffers()) -- reused, did not spawn another
  end)

  it('append: adds below the active buffer, blank-separated', function()
    local entry = connected()
    d:query():write_script(entry, 'new', 'SELECT 1', { table = 'p', schema = 'dbo' })
    local buf = vim.api.nvim_get_current_buf()
    bufs = { buf }
    d:query():write_script(entry, 'append', 'SELECT 2', { table = 'p', schema = 'dbo' })
    assert.same({ 'SELECT 1', '', 'SELECT 2' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)
end)
