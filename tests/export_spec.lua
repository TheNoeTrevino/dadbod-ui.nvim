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
    -- native sqlite csv: base argv + -csv -header, query appended (not stdin)
    assert.are.same({ 'CLIBIN', 'sqlite:/tmp/x.db', '-csv', '-header', 'SELECT * FROM t' }, cap.cmd)
    assert.is_nil(cap.stdin)
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
    -- postgres extract: base argv + --csv -c, query appended after -c
    assert.are.same({ 'CLIBIN', 'postgres://h/db', '--csv', '-c', 'SELECT * FROM t' }, cap.cmd)
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
end)
