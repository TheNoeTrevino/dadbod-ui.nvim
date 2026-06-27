-- Specs for the vim-dadbod bridge (the engine boundary).
--
-- These assert the pass-through primitives against a real, loaded vim-dadbod,
-- plus one end-to-end async execution against a temporary SQLite database
-- (guarded by the presence of the `sqlite3` binary).

local bridge = require('dadbod-ui.bridge')

describe('bridge: availability', function()
  it('reports vim-dadbod as available', function()
    assert.is_true(bridge.is_available())
  end)
end)

describe('bridge: url parsing', function()
  it('parses a network url into components (raw scheme)', function()
    local p = bridge.parse_url('postgres://user:secret@localhost:5432/mydb')
    assert.equals('postgres', p.scheme) -- RAW scheme, not canonicalized
    assert.equals('localhost', p.host)
    assert.equals('5432', p.port)
    assert.equals('user', p.user)
    assert.equals('secret', p.password)
    assert.equals('/mydb', p.path)
  end)

  it('parses a file-style (sqlite) url with opaque', function()
    local p = bridge.parse_url('sqlite:/tmp/x.db')
    assert.equals('sqlite', p.scheme)
    assert.equals('/tmp/x.db', p.opaque)
  end)

  it('scheme_of returns the raw scheme', function()
    assert.equals('postgres', bridge.scheme_of('postgres://localhost/db'))
  end)

  it('safe_url strips the password', function()
    local safe = bridge.safe_url('postgres://user:secret@localhost:5432/mydb')
    assert.equals('postgres://user@localhost:5432/mydb', safe)
    assert.is_nil(safe:match('secret'))
  end)
end)

describe('bridge: adapters', function()
  it('lists known schemes including the common engines', function()
    local schemes = bridge.schemes()
    local set = {}
    for _, s in ipairs(schemes) do
      set[s] = true
    end
    assert.is_true(set['postgresql'])
    assert.is_true(set['sqlite'])
    assert.is_true(set['mysql'])
    assert.is_true(set['sqlserver'])
  end)

  it('resolves raw schemes before adapter calls (postgres -> postgresql)', function()
    -- Would throw "no adapter for postgres" if the bridge did not resolve first.
    local ext = bridge.input_extension('postgres://localhost/db')
    assert.is_string(ext)
    assert.is_true(#ext > 0)
  end)

  it('reports adapter capabilities via supports()', function()
    assert.is_boolean(bridge.supports('sqlite:/tmp/x.db', 'interactive'))
  end)

  it('returns the default when an adapter lacks a function', function()
    local got = bridge.adapter_call('sqlite:/tmp/x.db', 'definitely_not_a_fn', {}, 'fallback')
    assert.equals('fallback', got)
  end)

  it('output_extension falls back to dbout', function()
    assert.is_string(bridge.output_extension('sqlite:/tmp/x.db'))
  end)
end)

describe('bridge: concurrent introspection (fan-out / WaitGroup)', function()
  it('builds the per-adapter argv via dadbod', function()
    local argv = bridge.command('sqlite:/tmp/x.db')
    assert.is_table(argv)
    assert.equals('sqlite3', argv[1])
  end)

  it('fans out commands in parallel: wall-clock ~ slowest, not sum', function()
    local done = false
    local start = vim.uv.hrtime()
    -- 3 x 0.3s: ~0.9s sequential, ~0.3s in parallel.
    bridge.run_many({
      { cmd = { 'sleep', '0.3' } },
      { cmd = { 'sleep', '0.3' } },
      { cmd = { 'sleep', '0.3' } },
    }, function()
      done = true
    end)
    assert.is_true(vim.wait(3000, function()
      return done
    end, 10))
    local elapsed_ms = (vim.uv.hrtime() - start) / 1e6
    assert.is_true(elapsed_ms < 750, ('expected parallel (<750ms), got %dms'):format(elapsed_ms))
  end)

  it('collects results aligned to the input specs', function()
    if vim.fn.executable('sqlite3') ~= 1 then
      pending('sqlite3 not installed')
      return
    end
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local db = dir .. '/c.db'
    vim.fn.system({ 'sqlite3', db, 'CREATE TABLE t(a); INSERT INTO t VALUES(1),(2),(3);' })

    local results, done
    bridge.run_many({
      { cmd = { 'sqlite3', db, 'SELECT count(*) FROM t' } },
      { cmd = { 'sqlite3', db, 'SELECT a FROM t ORDER BY a LIMIT 1' } },
    }, function(r)
      results, done = r, true
    end)
    assert.is_true(vim.wait(4000, function()
      return done
    end, 10))
    assert.equals('3', vim.trim(results[1].stdout))
    assert.equals('1', vim.trim(results[2].stdout))
    assert.equals(0, results[1].code)
    vim.fn.delete(dir, 'rf')
  end)
end)

describe('bridge: async execution', function()
  local has_sqlite = vim.fn.executable('sqlite3') == 1
  local dir, db_path

  before_each(function()
    if not has_sqlite then
      return
    end
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    db_path = dir .. '/test.db'
    vim.fn.system({
      'sqlite3',
      db_path,
      "CREATE TABLE greet(msg TEXT); INSERT INTO greet VALUES('hello_async');",
    })
  end)

  after_each(function()
    if dir then
      vim.fn.delete(dir, 'rf')
      dir, db_path = nil, nil
    end
    pcall(vim.api.nvim_clear_autocmds, { event = 'User' })
  end)

  it('runs a query through :DB and fires pre/post with the output file', function()
    if not has_sqlite then
      pending('sqlite3 not installed')
      return
    end

    local pre_file, post_file, rows
    bridge.on_pre(function(info)
      pre_file = info.output_file
    end, { once = true })
    bridge.on_post(function(info)
      post_file = info.output_file
      rows = vim.fn.readfile(info.output_file)
    end, { once = true })

    bridge.execute('sqlite:' .. db_path, 'SELECT msg FROM greet')

    local ok = vim.wait(5000, function()
      return post_file ~= nil
    end, 25)

    assert.is_true(ok, 'query did not complete in time')
    assert.is_string(pre_file)
    assert.equals(pre_file, post_file)
    assert.is_truthy(table.concat(rows, '\n'):match('hello_async'))
  end)
end)
