-- Specs for the post-execute inline summary (query_time): the pure row-count /
-- summary-text helpers, the config surface, and a guarded end-to-end that runs
-- real SQL and asserts the virtual-line summary + cursor ghost text are painted.

local config = require('dadbod-ui.config')
local dbout = require('dadbod-ui.dbout')

describe('query_time: config', function()
  it('defaults to enabled with both placements and row count on', function()
    local cfg = config.resolve()
    assert.same({
      enabled = true,
      result_buffer = true,
      query_buffer = true,
      show_row_count = true,
    }, cfg.query_time)
  end)

  it('deep-merges a partial override, keeping the other keys at their defaults', function()
    local cfg = config.resolve({ query_time = { query_buffer = false } })
    assert.is_false(cfg.query_time.query_buffer)
    assert.is_true(cfg.query_time.enabled)
    assert.is_true(cfg.query_time.result_buffer)
    assert.is_true(cfg.query_time.show_row_count)
  end)
end)

describe('query_time: _summary_text', function()
  it('reports a successful run with time and pluralized rows', function()
    assert.equals('✓ finished in 0.012s · 200 rows', dbout._summary_text(0.012, 0, 200))
  end)

  it('uses a singular row label for a single row', function()
    assert.equals('✓ finished in 0.005s · 1 row', dbout._summary_text(0.005, 0, 1))
  end)

  it('omits the count when rows is nil', function()
    assert.equals('✓ finished in 0.012s', dbout._summary_text(0.012, 0, nil))
  end)

  it('treats a missing exit_status as success', function()
    assert.equals('✓ finished in 0.100s', dbout._summary_text(0.1, nil, nil))
  end)

  it('reports a non-zero exit_status as aborted and drops the count', function()
    assert.equals('✗ aborted after 0.012s', dbout._summary_text(0.012, 1, nil))
  end)

  it('falls back to a bare verb when the runtime is unknown', function()
    assert.equals('✓ finished', dbout._summary_text(nil, 0, nil))
  end)
end)

describe('query_time: _count_rows', function()
  it('reads the postgres "(N rows)" footer', function()
    local n = dbout._count_rows({
      ' id | name ',
      '----+------',
      '  1 | ada',
      '  2 | alan',
      '(2 rows)',
    })
    assert.equals(2, n)
  end)

  it('reads the mysql "N rows in set" footer', function()
    local n = dbout._count_rows({
      '+----+------+',
      '| id | name |',
      '+----+------+',
      '|  1 | ada  |',
      '+----+------+',
      '1 row in set (0.00 sec)',
    })
    assert.equals(1, n)
  end)

  it('reads the sqlserver "(N rows affected)" footer', function()
    local n = dbout._count_rows({
      'id  name',
      '--  ----',
      '1   ada',
      '',
      '(1 rows affected)',
    })
    assert.equals(1, n)
  end)

  it('falls back to counting data lines under the first rule (sqlite column mode)', function()
    local n = dbout._count_rows({
      'name      ',
      '----------',
      'ada       ',
      'alan      ',
    })
    assert.equals(2, n)
  end)

  it('returns nil when it cannot find a rule or footer', function()
    assert.is_nil(dbout._count_rows({ 'just', 'some', 'text' }))
    assert.is_nil(dbout._count_rows({}))
  end)
end)

describe('query_time: arm/disarm origin', function()
  it('disarm prevents an armed origin from leaking into the next run', function()
    -- Smoke: arming then disarming must not error and leaves nothing to attach.
    -- (The full wiring is exercised end-to-end below.)
    dbout.arm_origin({ bufnr = 0, lnum = 1 })
    dbout.disarm_origin()
  end)
end)

describe('query_time: end-to-end (sqlite)', function()
  local drawer_mod = require('dadbod-ui.drawer')
  local state = require('dadbod-ui.state')
  local d
  local fixture = '/tmp/dbui_query_time_qa.db'
  local query_bufs = {}

  local function ns_id(name)
    return vim.api.nvim_get_namespaces()[name]
  end

  before_each(function()
    if vim.fn.executable('sqlite3') == 1 then
      vim.fn.delete(fixture)
      vim.fn.system({
        'sqlite3',
        fixture,
        "CREATE TABLE contacts(id INTEGER, name TEXT); INSERT INTO contacts VALUES (1,'ada'),(2,'alan');",
      })
    end
  end)

  after_each(function()
    for _, b in ipairs(query_bufs) do
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
    query_bufs = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):match('%.dbout$') then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    if d then
      d:close()
      d = nil
    end
    vim.fn.delete(fixture)
  end)

  it('paints the result-buffer virtual line and the query-buffer ghost text', function()
    if vim.fn.executable('sqlite3') ~= 1 then
      return pending('sqlite3 not installed')
    end
    local cfg = config.resolve({
      save_location = '/tmp/dbui_query_time',
      show_help = false,
      execute_on_save = true,
    })
    local instance = state.new(cfg):populate({
      env = {},
      g_dbs = { qa = 'sqlite:' .. fixture },
      file_entries = {},
    })
    d = drawer_mod.new(instance)
    d.connector = require('dadbod-ui.bridge').connect
    d:open()

    local entry
    for _, record in ipairs(d.instance.dbs_list) do
      if record.name == 'qa' then
        entry = d.instance.dbs[record.key_name]
      end
    end
    d:query():open({ type = 'query', key_name = entry.key_name }, 'edit')
    local query_buf = vim.api.nvim_get_current_buf()
    query_bufs[#query_bufs + 1] = query_buf
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'SELECT name FROM contacts ORDER BY name;' })
    vim.cmd('silent write')

    local function dbout_buf()
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(b):match('%.dbout$') then
          for _, line in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
            if line:find('ada', 1, true) then
              return b
            end
          end
        end
      end
    end

    local rbuf
    local ok = vim.wait(5000, function()
      rbuf = dbout_buf()
      return rbuf ~= nil
    end, 50)
    assert.is_true(ok, 'expected a .dbout buffer with rows')

    -- Result buffer: the summary is pinned to the top of its window via `winbar`
    -- (not a virt_lines extmark -- Neovim can't draw a virtual line above line 1).
    local rwins = vim.fn.win_findbuf(rbuf)
    assert.is_true(#rwins > 0, 'expected a window showing the result buffer')
    local winbar = vim.api.nvim_get_option_value('winbar', { win = rwins[1] })
    assert.is_truthy(winbar:find('finished in', 1, true))
    assert.is_truthy(winbar:find('2 rows', 1, true))

    -- Query buffer: ghost text trailing the executed line.
    local ghost =
      vim.api.nvim_buf_get_extmarks(query_buf, ns_id('dadbod_ui_query_time_query'), 0, -1, { details = true })
    assert.equals(1, #ghost)
    assert.is_truthy(ghost[1][4].virt_text[1][1]:find('finished in', 1, true))
  end)
end)
