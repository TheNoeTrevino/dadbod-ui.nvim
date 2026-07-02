-- Specs for the user-facing scripting API (`dadbod-ui.api`): name resolution,
-- error paths for unknown connections, programmatic `add`, and a guarded sqlite
-- end-to-end for the data-returning verbs (connect / introspect / query_sync).

local api = require('dadbod-ui.api')
local state = require('dadbod-ui.state')

-- Seed the session singleton with injected connections. The API reads through
-- `state.get()`, so we drive discovery via `vim.g.dbs` and reset around it.
local function seed(g_dbs, overrides)
  vim.g.dbs = g_dbs
  local opts = vim.tbl_extend('force', { save_location = '/tmp/dbui_api', show_help = false }, overrides or {})
  state.setup(opts)
  state.get() -- force discovery now
end

describe('api: surface', function()
  it('exposes a Lua function for every user command', function()
    -- Each :DBUI* command must have an api equivalent so everything is scriptable.
    for _, fn in ipairs({
      'open', -- :DBUI
      'toggle', -- :DBUIToggle
      'close', -- :DBUIClose
      'add_connection', -- :DBUIAddConnection
      'find_buffer', -- :DBUIFindBuffer
      'switch_buffer', -- :DBUISwitchBuffer
      'rename_buffer', -- :DBUIRenameBuffer
      'last_query_info', -- :DBUILastQueryInfo
      'cancel_query', -- :DBUICancelQuery
      'export_result', -- :DBUIExportResult
    }) do
      assert.equals('function', type(api[fn]), 'missing api.' .. fn)
    end
  end)
end)

describe('api: resolution and error paths', function()
  after_each(function()
    vim.g.dbs = nil
    state.reset()
  end)

  it('lists injected connections', function()
    seed({ dev = 'postgres://h/dev', qa = 'sqlite:/tmp/x.db' })
    local names = vim.tbl_map(function(c)
      return c.name
    end, api.list())
    assert.is_true(vim.tbl_contains(names, 'dev'))
    assert.is_true(vim.tbl_contains(names, 'qa'))
  end)

  it('returns connection info by name, nil for unknown', function()
    seed({ dev = 'postgres://h/dev' })
    local info = api.info('dev')
    assert.is_truthy(info)
    -- `url` is the resolved url (schemes canonicalize: postgres -> postgresql).
    assert.is_truthy(info.url:match('h/dev'))
    assert.equals('postgresql', info.scheme) -- canonical adapter scheme
    assert.is_false(info.connected)
    assert.is_nil(api.info('nope'))
  end)

  it('is_connected is false for a fresh or unknown connection', function()
    seed({ dev = 'postgres://h/dev' })
    assert.is_false(api.is_connected('dev'))
    assert.is_false(api.is_connected('nope'))
  end)

  it('query_sync errors for an unknown connection', function()
    seed({ dev = 'postgres://h/dev' })
    local rows, err = api.query_sync('nope', 'select 1')
    assert.is_nil(rows)
    assert.is_truthy(err and err:match('no connection named nope'))
  end)

  it('query / connect / introspect report unknown names through their callback', function()
    seed({ dev = 'postgres://h/dev' })
    local q_err, c_err, i_err
    api.query('nope', 'select 1', function(_, err)
      q_err = err
    end)
    api.connect('nope', function(_, err)
      c_err = err
    end)
    api.introspect('nope', function(_, err)
      i_err = err
    end)
    assert.is_truthy(q_err and q_err:match('no connection named nope'))
    assert.is_truthy(c_err and c_err:match('no connection named nope'))
    assert.is_truthy(i_err and i_err:match('no connection named nope'))
  end)

  it('switch_buffer errors when the current buffer is not a query buffer', function()
    seed({ dev = 'postgres://h/dev' })
    vim.cmd('enew')
    local ok, err = api.switch_buffer('dev')
    assert.is_false(ok)
    assert.is_truthy(err and err:match('not a dadbod%-ui query buffer'))
    vim.cmd('silent! %bwipeout!')
  end)

  it('execute / export report unknown names synchronously', function()
    seed({ dev = 'postgres://h/dev' })
    local ok1, err1 = api.execute('nope', 'select 1')
    local ok2, err2 = api.export({ name = 'nope', sql = 'select 1', format = 'csv', path = '/tmp/x.csv' })
    assert.is_false(ok1)
    assert.is_false(ok2)
    assert.is_truthy(err1 and err1:match('no connection named nope'))
    assert.is_truthy(err2 and err2:match('no connection named nope'))
  end)
end)

describe('api: add (programmatic)', function()
  local dir
  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    seed({}, { save_location = dir })
  end)
  after_each(function()
    vim.g.dbs = nil
    state.reset()
    if dir then
      vim.fn.delete(dir, 'rf')
      dir = nil
    end
  end)

  it('writes a connection to the store and makes it resolvable', function()
    local ok, err = api.add({ name = 'added', url = 'sqlite:/tmp/added.db' })
    assert.is_true(ok, err)
    assert.is_truthy(api.info('added'))
    assert.equals('sqlite:/tmp/added.db', api.info('added').url)
  end)
end)

describe('api: grouped connections (name reused across groups)', function()
  local dir
  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    -- Two connections both named 'prod', disambiguated only by their group.
    require('dadbod-ui.connections').write_file(dir .. '/connections.json', {
      { name = 'prod', url = 'postgres://h/analytics', group = 'analytics' },
      { name = 'prod', url = 'postgres://h/billing', group = 'billing' },
      { name = 'stage', url = 'postgres://h/stage' },
    })
    vim.g.dbs = nil
    require('dadbod-ui.state').setup({ save_location = dir, show_help = false })
    require('dadbod-ui.state').get()
  end)
  after_each(function()
    state.reset()
    if dir then
      vim.fn.delete(dir, 'rf')
      dir = nil
    end
  end)

  it('list exposes group and key_name for disambiguation', function()
    local by_group = {}
    for _, c in ipairs(api.list()) do
      if c.name == 'prod' then
        by_group[c.group] = c.key_name
      end
    end
    assert.equals('analytics_prod_file', by_group.analytics)
    assert.equals('billing_prod_file', by_group.billing)
  end)

  it('resolves a grouped connection via group/name', function()
    -- url is the resolved url (postgres -> postgresql), so match the distinct path.
    assert.is_truthy(api.info('analytics/prod').url:match('h/analytics$'))
    assert.is_truthy(api.info('billing/prod').url:match('h/billing$'))
  end)

  it('resolves via full key_name', function()
    assert.is_truthy(api.info('billing_prod_file').url:match('h/billing$'))
  end)

  it('resolves an ungrouped connection by bare name', function()
    assert.is_truthy(api.info('stage').url:match('h/stage$'))
  end)

  it('errors for an unknown group/name', function()
    local rows, err = api.query_sync('marketing/prod', 'select 1')
    assert.is_nil(rows)
    assert.is_truthy(err and err:match('no connection named marketing/prod'))
  end)

  it('switch_buffer resolves group/name before reaching the drawer', function()
    vim.cmd('enew') -- not a query buffer
    -- A resolvable group/name gets past name resolution (then fails on the buffer).
    local ok1, err1 = api.switch_buffer('billing/prod')
    assert.is_false(ok1)
    assert.is_truthy(err1 and err1:match('not a dadbod%-ui query buffer'))
    -- An unresolvable one fails at resolution.
    local ok2, err2 = api.switch_buffer('marketing/prod')
    assert.is_false(ok2)
    assert.is_truthy(err2 and err2:match('no connection named marketing/prod'))
    vim.cmd('silent! %bwipeout!')
  end)
end)

describe('api: sqlite end-to-end (guarded)', function()
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

  it('query_sync connects and returns raw output lines', function()
    if vim.fn.executable('sqlite3') ~= 1 then
      pending('sqlite3 not installed')
      return
    end
    local rows, err = api.query_sync('qa', 'select name from contacts')
    assert.is_nil(err)
    assert.is_truthy(rows)
    -- Raw adapter output: the sqlite3 CLI pads/formats cells differently across
    -- versions, so match the value as a substring rather than an exact line.
    assert.is_truthy(vim.iter(rows):any(function(line)
      return line:find('ada', 1, true) ~= nil
    end))
    assert.is_true(api.is_connected('qa'))
  end)

  it('query_sync surfaces a query error', function()
    if vim.fn.executable('sqlite3') ~= 1 then
      pending('sqlite3 not installed')
      return
    end
    local rows, err = api.query_sync('qa', 'select * from does_not_exist')
    assert.is_nil(rows)
    assert.is_truthy(err)
  end)

  it('introspect returns the real tables', function()
    if vim.fn.executable('sqlite3') ~= 1 then
      pending('sqlite3 not installed')
      return
    end
    local done, data, ierr
    api.introspect('qa', function(d, e)
      done, data, ierr = true, d, e
    end)
    vim.wait(2000, function()
      return done
    end)
    assert.is_nil(ierr)
    assert.is_truthy(data)
    assert.is_true(vim.tbl_contains(data.tables, 'contacts'))
  end)
end)
