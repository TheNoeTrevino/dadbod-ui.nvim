-- Specs for dadbod-ui.export orchestrator. The engine bridge, process runner,
-- file writer and notifier are injected, so the whole flow is exercised without a
-- database: native passthrough (CLI stdout verbatim), extract+format, command
-- construction, and every failure notification.

local export = require('dadbod-ui.export')

-- A capturing dep-set. `stdout`/`code`/`stderr` shape the fake CLI result; the
-- captured cmd/stdin/written/notes let assertions inspect what happened.
local function deps(opts)
  opts = opts or {}
  local cap = { written = {}, notes = {} }
  return cap,
    {
      bridge = {
        command = function(url)
          cap.url = url
          return { 'CLIBIN', url }
        end,
      },
      run = function(cmd, stdin, on_done)
        cap.cmd = cmd
        cap.stdin = stdin
        on_done({ code = opts.code or 0, stdout = opts.stdout or '', stderr = opts.stderr or '' })
      end,
      write = function(path, content)
        if opts.write_fails then
          return false, 'disk full'
        end
        cap.written = { path = path, content = content }
        return true
      end,
      notify = {
        info = function(msg)
          cap.notes[#cap.notes + 1] = { kind = 'info', msg = msg }
        end,
        error = function(msg)
          cap.notes[#cap.notes + 1] = { kind = 'error', msg = msg }
        end,
      },
      -- Overwrite guard: default the injected confirm to yes so file existence
      -- never blocks a test; the overwrite tests override it explicitly.
      confirm = function()
        return true
      end,
    }
end

describe('export.export: native passthrough', function()
  it('writes the CLI stdout verbatim for a sqlite -csv (native) export', function()
    local cap, d = deps({ stdout = 'id,name\n1,Ann\n' })
    export.export({
      url = 'sqlite:/tmp/x.db',
      scheme = 'sqlite',
      format = 'csv',
      query = 'SELECT * FROM t',
      path = '/tmp/out.csv',
      prefer_native = true,
    }, d)
    -- native sqlite csv: base argv + -init NULLDEV -csv -header; query on stdin
    -- (leading-dash safe), NOT a positional arg
    local nulldev = vim.fn.has('win32') == 1 and 'NUL' or '/dev/null'
    assert.are.same({ 'CLIBIN', 'sqlite:/tmp/x.db', '-init', nulldev, '-csv', '-header' }, cap.cmd)
    assert.are.equal('SELECT * FROM t', cap.stdin)
    assert.are.equal('id,name\n1,Ann\n', cap.written.content) -- verbatim, not re-parsed
    assert.are.equal('/tmp/out.csv', cap.written.path)
    assert.are.equal('info', cap.notes[1].kind)
  end)
end)

describe('export.export: extract + format', function()
  it('parses the CSV extract and runs the JSON formatter for postgres', function()
    local cap, d = deps({ stdout = 'id,name\n1,Ann\n2,Bob\n' })
    export.export({
      url = 'postgres://h/db',
      scheme = 'postgres',
      format = 'json',
      query = 'SELECT * FROM t',
      path = '/tmp/out.json',
      source = 't',
      prefer_native = true, -- json is NOT native for postgres, so still extract+format
    }, d)
    -- postgres extract: base argv + --no-psqlrc --csv -c, query appended after -c
    assert.are.same({ 'CLIBIN', 'postgres://h/db', '--no-psqlrc', '--csv', '-c', 'SELECT * FROM t' }, cap.cmd)
    assert.is_truthy(cap.written.content:find('"t": [', 1, true)) -- wrapped under source
    assert.is_truthy(cap.written.content:find('"name" : "Ann"', 1, true))
    assert.is_truthy(cap.written.content:find('"name" : "Bob"', 1, true))
    assert.are.equal('info', cap.notes[1].kind)
    assert.is_truthy(cap.notes[1].msg:find('2 rows', 1, true)) -- row count reported
  end)

  it('feeds the query on stdin for mysql', function()
    local cap, d = deps({ stdout = 'id\tname\n1\tAnn\n' })
    export.export({
      url = 'mysql://h/db',
      scheme = 'mysql',
      format = 'json',
      query = 'SELECT * FROM t',
      path = '/tmp/o.json',
      prefer_native = true,
    }, d)
    assert.are.same({ 'CLIBIN', 'mysql://h/db', '--batch' }, cap.cmd)
    assert.are.equal('SELECT * FROM t', cap.stdin)
  end)
end)

describe('export.export: failure modes', function()
  it('rejects an unsupported adapter', function()
    local cap, d = deps()
    export.export({ scheme = 'oracle', format = 'csv', path = '/tmp/x' }, d)
    assert.are.equal('error', cap.notes[1].kind)
    assert.is_truthy(cap.notes[1].msg:find('not supported', 1, true))
    assert.is_nil(cap.cmd) -- never ran the CLI
  end)

  it('surfaces the CLI stderr on a non-zero exit', function()
    local cap, d = deps({ code = 1, stderr = 'syntax error near "FRM"' })
    export.export({
      url = 'sqlite:/x',
      scheme = 'sqlite',
      format = 'csv',
      query = 'FRM t',
      path = '/tmp/x',
      prefer_native = true,
    }, d)
    assert.are.equal('error', cap.notes[1].kind)
    assert.is_truthy(cap.notes[1].msg:find('syntax error', 1, true))
    assert.is_nil(cap.written.path) -- nothing written
  end)

  it('reports a write failure', function()
    local cap, d = deps({ stdout = 'a\n1\n', write_fails = true })
    export.export({
      url = 'sqlite:/x',
      scheme = 'sqlite',
      format = 'csv',
      query = 'SELECT 1',
      path = '/bad/x',
      prefer_native = true,
    }, d)
    assert.are.equal('error', cap.notes[1].kind)
    assert.is_truthy(cap.notes[1].msg:find('disk full', 1, true))
  end)

  it('rejects a format the adapter cannot produce / an unknown format', function()
    local cap, d = deps()
    export.export({
      url = 'sqlite:/x',
      scheme = 'sqlite',
      format = 'pdf', -- not an export format
      query = 'SELECT 1',
      path = '/tmp/x',
    }, d)
    assert.are.equal('error', cap.notes[1].kind)
    assert.is_truthy(cap.notes[1].msg:find("'pdf' is not available", 1, true))
    assert.is_nil(cap.cmd) -- never ran the CLI
  end)

  it('exports an empty result (header only) without erroring, reporting 0 rows', function()
    local cap, d = deps({ stdout = 'id,name\n' }) -- 0 data rows
    export.export({
      url = 'postgres://h/db',
      scheme = 'postgres',
      format = 'json',
      query = 'SELECT * FROM t WHERE 1=0',
      path = '/tmp/empty.json',
      source = 't',
      prefer_native = true, -- json not native for postgres -> extract+format
    }, d)
    assert.are.equal('info', cap.notes[1].kind)
    assert.is_truthy(cap.notes[1].msg:find('0 rows', 1, true))
    assert.is_truthy(cap.written.content:find('"t": []', 1, true)) -- empty array, valid file
  end)

  it('writes an empty native result verbatim without erroring', function()
    local cap, d = deps({ stdout = '' })
    export.export({
      url = 'sqlite:/x',
      scheme = 'sqlite',
      format = 'csv',
      query = 'SELECT 1 WHERE 0',
      path = '/tmp/e.csv',
      prefer_native = true,
    }, d)
    assert.are.equal('info', cap.notes[1].kind)
    assert.are.equal('', cap.written.content)
  end)

  it('writes valid [] for an empty native sqlite JSON result (sqlite3 -json emits nothing)', function()
    local cap, d = deps({ stdout = '' })
    export.export({
      url = 'sqlite:/x',
      scheme = 'sqlite',
      format = 'json', -- native for sqlite
      query = 'SELECT * FROM t WHERE 0',
      path = '/tmp/empty.json',
      prefer_native = true,
    }, d)
    assert.are.equal('info', cap.notes[1].kind)
    assert.are.equal('[]', cap.written.content) -- not an empty/invalid file
  end)
end)

describe('export.resolve_buffer: missing stored query', function()
  it('errors when the result buffer has no readable input file', function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.b[buf].db = { db_url = 'sqlite:/tmp/x.db', input = '/nonexistent/path.sql' }
    local info, err = export.resolve_buffer(buf)
    assert.is_nil(info)
    assert.is_truthy(err:find('No stored query', 1, true))
  end)
end)

describe('export._write (real writer)', function()
  it('writes content with exactly one trailing newline, preserving embedded newlines', function()
    local path = vim.fn.tempname() .. '.csv'
    local ok = export._write(path, 'a,b\n1,"x\ny"')
    assert.is_true(ok)
    -- the file has 3 physical lines: header, and the multi-line quoted field
    assert.are.same({ 'a,b', '1,"x', 'y"' }, vim.fn.readfile(path))
  end)
end)

describe('export.resolve_buffer', function()
  it('recovers url, scheme, query and source from a dbout buffer', function()
    local input = vim.fn.tempname() .. '.sql'
    vim.fn.writefile({ 'SELECT * FROM widgets' }, input)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.b[buf].db = { db_url = 'sqlite:/tmp/x.db', input = input }
    vim.b[buf].dbui_table_name = 'widgets'
    local info, err = export.resolve_buffer(buf)
    assert.is_nil(err)
    assert.are.equal('sqlite:/tmp/x.db', info.url)
    assert.are.equal('sqlite', info.scheme)
    assert.are.equal('SELECT * FROM widgets', info.query)
    assert.are.equal('widgets', info.source)
  end)

  it('errors when the buffer is not a result buffer', function()
    local buf = vim.api.nvim_create_buf(false, true)
    local info, err = export.resolve_buffer(buf)
    assert.is_nil(info)
    assert.is_truthy(err:find('Not a query result buffer', 1, true))
  end)
end)

describe('export.default_path', function()
  it('maps formats to extensions (markdown -> md) under cwd', function()
    assert.are.equal(vim.fn.getcwd() .. '/widgets.csv', export.default_path('widgets', 'csv'))
    assert.are.equal(vim.fn.getcwd() .. '/widgets.md', export.default_path('widgets', 'markdown'))
    assert.are.equal(vim.fn.getcwd() .. '/export.json', export.default_path('', 'json'))
  end)

  it('honours a configured default directory (expanding ~)', function()
    assert.are.equal('/exports/widgets.csv', export.default_path('widgets', 'csv', '/exports'))
    assert.are.equal(vim.fn.expand('~') .. '/widgets.json', export.default_path('widgets', 'json', '~'))
    -- empty dir falls back to cwd
    assert.are.equal(vim.fn.getcwd() .. '/widgets.csv', export.default_path('widgets', 'csv', ''))
  end)
end)

describe('export.format_opts (config wiring)', function()
  it('folds the top-level coerce_numbers into the per-format opts', function()
    local cfg = { coerce_numbers = true, json = { wrap_table_name = false } }
    local opts = export.format_opts(cfg, 'json', 'postgres')
    assert.is_true(opts.coerce_numbers)
    assert.is_false(opts.wrap_table_name)
  end)

  it('derives quote_identifiers for SQL from the adapter quote flag', function()
    assert.is_true(export.format_opts({}, 'sql', 'postgres').quote_identifiers) -- pg quotes
    assert.is_false(export.format_opts({}, 'sql', 'mysql').quote_identifiers) -- mysql does not
    assert.is_false(export.format_opts({}, 'sql', 'sqlite').quote_identifiers) -- sqlite: no quote flag
  end)
end)

describe('export.resolve_buffer: source derivation', function()
  -- the dbout buffer carries no dbui_table_name, so source comes from the query
  local function buf_with(query)
    local input = vim.fn.tempname() .. '.sql'
    vim.fn.writefile(vim.split(query, '\n'), input)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.b[buf].db = { db_url = 'sqlite:/tmp/x.db', input = input }
    return buf
  end

  it('derives the table name from FROM (quoted / schema-qualified)', function()
    assert.are.equal('widgets', export.resolve_buffer(buf_with('SELECT * FROM "widgets" LIMIT 5')).source)
    assert.are.equal('orders', export.resolve_buffer(buf_with('select a,b from public.orders o')).source)
  end)

  it("falls back to 'results' for a query with no plain FROM (never a temp basename)", function()
    assert.are.equal('results', export.resolve_buffer(buf_with('SELECT 1')).source)
  end)

  it('still prefers an explicit dbui_table_name when present', function()
    local b = buf_with('SELECT * FROM t')
    vim.b[b].dbui_table_name = 'real_table'
    assert.are.equal('real_table', export.resolve_buffer(b).source)
  end)
end)

describe('export.export_interactive', function()
  -- Build a real dbout buffer + the injected pickers/runner so the whole picker
  -- -> prompt -> export flow runs without a UI or a database.
  local function setup_buffer()
    local input = vim.fn.tempname() .. '.sql'
    vim.fn.writefile({ 'SELECT * FROM widgets' }, input)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.b[buf].db = { db_url = 'sqlite:/tmp/x.db', input = input }
    vim.b[buf].dbui_table_name = 'widgets'
    return buf
  end

  it('offers the adapter formats, defaults the path, and exports the chosen one', function()
    local buf = setup_buffer()
    local cap, base = deps({ stdout = 'id,name\n1,Ann\n' })
    local picked_items, prompted_default
    base.select = function(items, opts, on_choice)
      picked_items = items
      assert.are.equal('CSV', opts.format_item('csv')) -- DBeaver-style label
      on_choice('csv')
    end
    base.input = function(opts, on_confirm)
      prompted_default = opts.default
      on_confirm('/tmp/widgets.csv')
    end
    export.export_interactive(buf, base)
    assert.are.same({ 'csv', 'json', 'markdown', 'html', 'xml', 'sql', 'tsv' }, picked_items)
    assert.are.equal(vim.fn.getcwd() .. '/widgets.csv', prompted_default)
    assert.are.equal('/tmp/widgets.csv', cap.written.path)
    assert.are.equal('id,name\n1,Ann\n', cap.written.content) -- native sqlite csv verbatim
  end)

  it('aborts cleanly when the format picker is cancelled (no export)', function()
    local buf = setup_buffer()
    local cap, base = deps()
    base.select = function(_, _, on_choice)
      on_choice(nil)
    end
    base.input = function()
      error('input should not be prompted after cancel')
    end
    export.export_interactive(buf, base)
    assert.is_nil(cap.cmd)
    assert.are.equal(0, #cap.notes)
  end)

  it('errors when invoked on a non-result buffer', function()
    local cap, base = deps()
    export.export_interactive(vim.api.nvim_create_buf(false, true), base)
    assert.are.equal('error', cap.notes[1].kind)
  end)

  it('confirms before overwriting an existing file; cancels on no', function()
    local buf = setup_buffer()
    local existing = vim.fn.tempname() .. '.csv'
    vim.fn.writefile({ 'old' }, existing) -- make the target already exist
    local cap, base = deps({ stdout = 'id\n1\n' })
    base.select = function(_, _, on_choice)
      on_choice('csv')
    end
    base.input = function(_, on_confirm)
      on_confirm(existing)
    end
    local asked
    base.confirm = function(msg)
      asked = msg
      return false -- user declines
    end
    export.export_interactive(buf, base)
    assert.is_truthy(asked:find('exists', 1, true))
    assert.is_nil(cap.cmd) -- never ran the CLI
    assert.are.equal('info', cap.notes[#cap.notes].kind) -- "Export cancelled."
  end)

  it('proceeds when overwrite is confirmed', function()
    local buf = setup_buffer()
    local existing = vim.fn.tempname() .. '.csv'
    vim.fn.writefile({ 'old' }, existing)
    local cap, base = deps({ stdout = 'id\n1\n' })
    base.select = function(_, _, on_choice)
      on_choice('csv')
    end
    base.input = function(_, on_confirm)
      on_confirm(existing)
    end
    base.confirm = function()
      return true
    end
    export.export_interactive(buf, base)
    assert.are.equal(existing, cap.written.path) -- overwrote
  end)
end)

describe('export.query_for (pagination, DECISION-003)', function()
  local paged = {
    query = 'SELECT * FROM t LIMIT 200 OFFSET 400', -- the on-screen page SQL
    page = { original_sql = 'SELECT * FROM t', page = 3, page_size = 200 },
  }

  it("'full' (default) exports the un-paginated original_sql for a paged result", function()
    assert.are.equal('SELECT * FROM t', export.query_for(paged))
    assert.are.equal('SELECT * FROM t', export.query_for(paged, 'full'))
  end)

  it("'current' exports the on-screen page SQL", function()
    assert.are.equal('SELECT * FROM t LIMIT 200 OFFSET 400', export.query_for(paged, 'current'))
  end)

  it('a non-paginated result uses its stored query regardless of the choice', function()
    local plain = { query = 'SELECT 1', page = nil }
    assert.are.equal('SELECT 1', export.query_for(plain, 'full'))
    assert.are.equal('SELECT 1', export.query_for(plain, 'current'))
  end)
end)

describe('export.export_interactive (paginated buffer)', function()
  it('defaults to exporting the full query (original_sql), not the page', function()
    local input = vim.fn.tempname() .. '.sql'
    vim.fn.writefile({ 'SELECT * FROM t LIMIT 200 OFFSET 0' }, input) -- paged SQL on disk
    local buf = vim.api.nvim_create_buf(false, true)
    vim.b[buf].db = { db_url = 'sqlite:/tmp/x.db', input = input }
    vim.b[buf].dbui_page = { original_sql = 'SELECT * FROM t', page = 1, page_size = 200 }

    local cap, base = deps({ stdout = 'id\n1\n' })
    base.select = function(_, _, on_choice)
      on_choice('csv')
    end
    base.input = function(_, on_confirm)
      on_confirm('/tmp/o.csv')
    end
    export.export_interactive(buf, base) -- no page_choice => 'full'
    -- the FULL query (not the paged one) is sent; sqlite delivers it on stdin
    assert.are.equal('SELECT * FROM t', cap.stdin)
  end)
end)
