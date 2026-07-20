-- Specs for the explain-plan capability: the pure per-adapter wrapping rules
-- (dadbod-ui.explain) and the API verbs that drive them (explain / explain_sync
-- / explain_execute), including the user-facing error for an unsupported
-- adapter and the opt-in `analyze` gating.

local explain = require('dadbod-ui.explain')
local api = require('dadbod-ui.api')
local state = require('dadbod-ui.state')

-- Seed the session singleton with injected connections (mirrors api_spec).
local function seed(g_dbs, overrides)
  vim.g.dbs = g_dbs
  local opts =
    vim.tbl_extend('force', { save_location = '/tmp/dbui_explain', drawer = { show_help = false } }, overrides or {})
  state.setup(opts)
  state.get()
end

describe('explain: wrap', function()
  it('wraps plain EXPLAIN for the supported schemes', function()
    assert.equals('EXPLAIN select 1', explain.wrap('postgresql', 'select 1'))
    assert.equals('EXPLAIN select 1', explain.wrap('mysql', 'select 1'))
    assert.equals('EXPLAIN select 1', explain.wrap('mariadb', 'select 1'))
    assert.equals('EXPLAIN QUERY PLAN select 1', explain.wrap('sqlite', 'select 1'))
    assert.equals('EXPLAIN select 1', explain.wrap('clickhouse', 'select 1'))
    assert.is_truthy(explain.wrap('oracle', 'select 1'):match('^EXPLAIN PLAN FOR select 1;'))
    assert.is_truthy(explain.wrap('oracle', 'select 1'):match('DBMS_XPLAN%.DISPLAY'))
  end)

  it('normalizes raw scheme aliases to their canonical template', function()
    assert.equals('EXPLAIN select 1', explain.wrap('postgres', 'select 1'))
    assert.equals('EXPLAIN QUERY PLAN select 1', explain.wrap('sqlite3', 'select 1'))
  end)

  it('keeps % and pattern magic in the query literal', function()
    -- gsub replacement magic (%1, %%) must not touch the user's SQL.
    assert.equals(
      "EXPLAIN select * where name like '%foo%'",
      explain.wrap('postgresql', "select * where name like '%foo%'")
    )
  end)

  it('wraps EXPLAIN ANALYZE when opts.analyze is set', function()
    assert.equals('EXPLAIN ANALYZE select 1', explain.wrap('postgresql', 'select 1', { analyze = true }))
    assert.equals('EXPLAIN ANALYZE select 1', explain.wrap('mysql', 'select 1', { analyze = true }))
    -- MariaDB spells the executing form `ANALYZE <stmt>`.
    assert.equals('ANALYZE select 1', explain.wrap('mariadb', 'select 1', { analyze = true }))
  end)

  it('errors when analyze is requested but the adapter has no executing form', function()
    for _, scheme in ipairs({ 'sqlite', 'clickhouse', 'oracle' }) do
      local sql, err = explain.wrap(scheme, 'select 1', { analyze = true })
      assert.is_nil(sql)
      assert.is_truthy(err and err:match('EXPLAIN ANALYZE is not supported'))
    end
  end)

  it('wraps the structured JSON form when opts.format is json', function()
    assert.equals('EXPLAIN (FORMAT JSON) select 1', explain.wrap('postgresql', 'select 1', { format = 'json' }))
    -- The executing JSON form runs inside a rolled-back transaction so a DML
    -- statement under analysis never commits.
    local analyzed = explain.wrap('postgres', 'delete from t', { format = 'json', analyze = true })
    assert.is_truthy(analyzed:match('^BEGIN;'))
    assert.is_truthy(analyzed:match('EXPLAIN %(ANALYZE, BUFFERS, FORMAT JSON%) delete from t'))
    assert.is_truthy(analyzed:match('ROLLBACK;$'))
  end)

  it('errors on the JSON form for text-only EXPLAIN dialects', function()
    for _, scheme in ipairs({ 'sqlite', 'clickhouse', 'oracle' }) do
      local sql, err = explain.wrap(scheme, 'select 1', { format = 'json' })
      assert.is_nil(sql)
      assert.is_truthy(err and err:match('JSON explain plan is not supported'))
      assert.is_truthy(err and err:match('supported:'))
    end
  end)

  it('errors (nil, err) for an unsupported adapter and lists the supported ones', function()
    for _, scheme in ipairs({ 'sqlserver', 'bigquery', 'mongodb', 'no_such_adapter' }) do
      local sql, err = explain.wrap(scheme, 'select 1')
      assert.is_nil(sql)
      assert.is_truthy(err and err:match('explain plan is not supported for adapter ' .. scheme))
      assert.is_truthy(err and err:match('supported:'))
    end
  end)
end)

describe('explain: supports / supported_schemes', function()
  it('reports support per scheme (raw aliases included)', function()
    assert.is_true(explain.supports('postgresql'))
    assert.is_true(explain.supports('postgres'))
    assert.is_true(explain.supports('sqlite3'))
    assert.is_false(explain.supports('sqlserver'))
    assert.is_false(explain.supports('bigquery'))
  end)

  it('lists the supported schemes sorted (canonical adapter names)', function()
    local schemes = explain.supported_schemes()
    assert.same({ 'clickhouse', 'mariadb', 'mysql', 'oracle', 'postgres', 'sqlite' }, schemes)
  end)

  it('gates the structured JSON form separately from text EXPLAIN', function()
    assert.is_true(explain.supports_json('postgres'))
    assert.is_true(explain.supports_json('postgresql')) -- alias resolves
    assert.is_true(explain.supports_json('mysql'))
    assert.is_true(explain.supports_json('mariadb'))
    assert.is_false(explain.supports_json('sqlite')) -- text-only EXPLAIN
    assert.is_false(explain.supports_json('sqlserver')) -- no EXPLAIN at all
    assert.same({ 'mariadb', 'mysql', 'postgres' }, explain.json_schemes())
  end)

  it('rejects JSON analyze where the dialect has no executing JSON form', function()
    -- MySQL's EXPLAIN ANALYZE emits TREE text, never JSON; MariaDB has
    -- ANALYZE FORMAT=JSON.
    local sql, err = explain.wrap('mysql', 'select 1', { format = 'json', analyze = true })
    assert.is_nil(sql)
    assert.is_truthy(err and err:match('JSON EXPLAIN ANALYZE is not supported'))
    assert.equals(
      'ANALYZE FORMAT=JSON select 1',
      explain.wrap('mariadb', 'select 1', { format = 'json', analyze = true })
    )
  end)

  it('exposes the raw-output client argv for JSON capture', function()
    assert.same({ '--no-psqlrc', '--set=ON_ERROR_STOP=1', '-q', '-A', '-t' }, explain.json_args('postgresql'))
    assert.same({}, explain.json_args('sqlite')) -- none needed / unsupported
  end)
end)

describe('explain: api error paths', function()
  after_each(function()
    vim.g.dbs = nil
    state.reset()
  end)

  it('reports an unknown connection through the callback / return', function()
    seed({ dev = 'postgres://h/dev' })
    local q_err
    api.explain('nope', 'select 1', function(_, err)
      q_err = err
    end)
    assert.is_truthy(q_err and q_err:match('no connection named nope'))

    local rows, err = api.explain_sync('nope', 'select 1')
    assert.is_nil(rows)
    assert.is_truthy(err and err:match('no connection named nope'))

    local ok, eerr = api.explain_execute('nope', 'select 1')
    assert.is_false(ok)
    assert.is_truthy(eerr and eerr:match('no connection named nope'))
  end)

  it('surfaces the unsupported-adapter error before touching the engine', function()
    -- A sqlserver connection resolves fine, but has no explain template.
    seed({ mssql = 'sqlserver://sa@h/db' })
    local ok, err = api.explain_execute('mssql', 'select 1')
    assert.is_false(ok)
    assert.is_truthy(err and err:match('explain plan is not supported for adapter sqlserver'))

    local rows, serr = api.explain_sync('mssql', 'select 1')
    assert.is_nil(rows)
    assert.is_truthy(serr and serr:match('explain plan is not supported'))
  end)
end)

describe('explain: sqlite end-to-end (guarded)', function()
  local dir, db_path
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
      "CREATE TABLE contacts(id INTEGER, name TEXT); INSERT INTO contacts VALUES (1, 'ada');",
    })
    seed({ qa = 'sqlite:' .. db_path })
  end)
  after_each(function()
    vim.g.dbs = nil
    state.reset()
    if dir then
      vim.fn.delete(dir, 'rf')
      dir, db_path = nil, nil
    end
  end)

  it('explain_sync returns the query plan output', function()
    if vim.fn.executable('sqlite3') ~= 1 then
      pending('sqlite3 not installed')
      return
    end
    local rows, err = api.explain_sync('qa', 'select * from contacts')
    assert.is_nil(err)
    assert.is_truthy(rows)
    -- sqlite's EXPLAIN QUERY PLAN reports how it reads the table; the exact
    -- wording varies by version, so match the table name it must reference.
    assert.is_truthy(vim.iter(rows):any(function(line)
      return line:find('contacts', 1, true) ~= nil
    end))
    assert.is_true(api.info('qa').connected)
  end)
end)

-- The buffer-level dual (explain_query / explain_selection): it must read the
-- CURRENT query buffer's connection + text, wrap it in the adapter's EXPLAIN, and
-- run THAT (not the raw query) into the result window. Stubbing the engine's
-- `execute_lines` lets us assert the wrapped SQL with no DB binary -- mirroring
-- how query_buffers_spec drives a query buffer offline.
describe('explain: buffer-level (explain_query)', function()
  local drawer_mod = require('dadbod-ui.drawer')
  local config = require('dadbod-ui.config')
  local bridge = require('dadbod-ui.bridge')
  local notifications = require('dadbod-ui.notifications')

  local function make_drawer(g_dbs)
    local cfg = config.resolve({ save_location = '/tmp/dbui_explain_buf', drawer = { show_help = false } })
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

  local d, query_bufs, saved_execute_lines, sent
  before_each(function()
    require('helper').clean_ui()
    query_bufs = {}
    sent = nil
    -- Capture what the engine is asked to run instead of touching a real DB.
    saved_execute_lines = bridge.execute_lines
    bridge.execute_lines = function(lines)
      sent = lines
    end
  end)
  after_each(function()
    bridge.execute_lines = saved_execute_lines
    for _, b in ipairs(query_bufs) do
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
    if d then
      d:close()
      d = nil
    end
  end)

  -- Open a query buffer bound to `name`, seed it with `sql`, and focus it.
  local function open_query_buffer(name, sql)
    d:open()
    local entry = entry_named(d, name)
    d:query():open({ type = 'query', key_name = entry.key_name }, 'edit')
    query_bufs[#query_bufs + 1] = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(sql, '\n'))
    return entry
  end

  it('wraps the current buffer SQL in EXPLAIN and runs that', function()
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' })
    open_query_buffer('qa', 'select * from contacts')
    d:query():explain_query(false)
    assert.same({ 'EXPLAIN QUERY PLAN select * from contacts' }, sent)
  end)

  it('surfaces the unsupported-adapter error and runs nothing', function()
    d = make_drawer({ mssql = 'sqlserver://sa@h/db' })
    open_query_buffer('mssql', 'select 1')
    d:query():explain_query(false)
    assert.is_nil(sent) -- engine never invoked
    assert.is_truthy(notifications.get_last_msg():match('explain plan is not supported for adapter sqlserver'))
  end)

  it('rejects analyze on an adapter with no executing form', function()
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' })
    open_query_buffer('qa', 'select 1')
    d:query():explain_query(false, { analyze = true })
    assert.is_nil(sent)
    assert.is_truthy(notifications.get_last_msg():match('EXPLAIN ANALYZE is not supported'))
  end)

  it('errors on a buffer not attached to any database', function()
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' })
    d:open()
    vim.cmd('enew') -- a plain buffer, no b:dbui_db_key_name
    query_bufs[#query_bufs + 1] = vim.api.nvim_get_current_buf()
    d:query():explain_query(false)
    assert.is_nil(sent)
    assert.is_truthy(notifications.get_last_msg():match('Buffer not attached to any database'))
  end)
end)
