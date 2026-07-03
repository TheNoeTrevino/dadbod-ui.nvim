-- Specs for the optional `transform` hook on dadbod-ui.query's execute flow: a
-- synchronous last-mile rewrite of the runnable SQL (e.g. wrapping in EXPLAIN).
-- The engine is stubbed (bridge functions swapped out), so we assert on what would
-- be sent. The key behaviors: identity when omitted or when the hook returns nil
-- (fast `%DB` path preserved), rewrite runs from a temp file, and composition with
-- the bind-param substitution that runs BEFORE the transform.

local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')
local bridge = require('dadbod-ui.bridge')

local function make_drawer(overrides)
  local cfg =
    config.resolve(vim.tbl_extend('force', { save_location = '/tmp/dbui_tx', show_help = false }, overrides or {}))
  local instance = state.new(cfg):populate({ env = {}, g_dbs = { qa = 'sqlite:/tmp/qa.db' }, file_entries = {} })
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

describe('execute: transform hook', function()
  local d, query_buf
  local saved
  local calls

  before_each(function()
    calls = { buffer = 0, files = {} }
    saved = {
      execute_buffer = bridge.execute_buffer,
      execute_file = bridge.execute_file,
      input_extension = bridge.input_extension,
      can_cancel = bridge.can_cancel,
    }
    bridge.execute_buffer = function()
      calls.buffer = calls.buffer + 1
    end
    bridge.execute_file = function(file, url)
      table.insert(calls.files, vim.fn.readfile(file))
      calls.last_url = url
    end
    bridge.input_extension = function()
      return 'sql'
    end
    bridge.can_cancel = function()
      return false
    end
  end)

  after_each(function()
    for k, v in pairs(saved) do
      bridge[k] = v
    end
    if query_buf then
      pcall(vim.api.nvim_buf_delete, query_buf, { force = true })
      query_buf = nil
    end
    if d then
      d:close()
      d = nil
    end
  end)

  local function open_query(lines)
    d:open()
    local entry = entry_named(d, 'qa')
    d:query():open({ type = 'query', key_name = entry.key_name }, 'edit')
    query_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  end

  it('runs the rewritten SQL from a temp file, dropping the %DB fast path', function()
    d = make_drawer()
    open_query({ 'SELECT 1' })
    -- Wrapping in EXPLAIN QUERY PLAN is non-paginatable, so it runs verbatim (no
    -- LIMIT/OFFSET) via the tempfile path -- and never through %DB.
    d:query():execute_query(false, function(sql)
      return 'EXPLAIN QUERY PLAN\n' .. sql
    end)
    assert.equals(0, calls.buffer)
    assert.same({ { 'EXPLAIN QUERY PLAN', 'SELECT 1' } }, calls.files)
    assert.equals(entry_named(d, 'qa').conn, calls.last_url)
  end)

  it('passes the buffer SQL as a single string to the transform', function()
    d = make_drawer()
    open_query({ 'SELECT 1', 'FROM t' })
    local seen
    d:query():execute_query(false, function(sql)
      seen = sql
      return sql
    end)
    assert.equals('SELECT 1\nFROM t', seen)
  end)

  it('runs the query unchanged when the transform returns nil', function()
    d = make_drawer()
    open_query({ 'SELECT 1' })
    d:query():execute_query(false, function(_sql)
      return nil
    end)
    -- nil is the identity: sqlite paginates the plain SELECT as page 1, exactly as
    -- a no-transform run would.
    assert.equals(0, calls.buffer)
    assert.same({ { 'SELECT 1 LIMIT 200 OFFSET 0' } }, calls.files)
  end)

  it('substitutes bind params BEFORE the transform sees the SQL', function()
    d = make_drawer()
    open_query({ 'SELECT * FROM contacts WHERE id = :id' })
    d:query().input = function(_opts, on_confirm)
      on_confirm('5')
    end
    local seen
    d:query():execute_query(false, function(sql)
      seen = sql
      return 'EXPLAIN QUERY PLAN\n' .. sql
    end)
    -- The transform receives the substituted query, not the raw :id placeholder.
    assert.equals('SELECT * FROM contacts WHERE id = 5', seen)
    assert.same({ { 'EXPLAIN QUERY PLAN', 'SELECT * FROM contacts WHERE id = 5' } }, calls.files)
  end)

  it('omitting the transform preserves the %DB fast path', function()
    d = make_drawer()
    open_query({ 'SELECT 1 LIMIT 10' }) -- already paged: stays on the raw %DB path
    d:query():execute_query()
    assert.equals(1, calls.buffer)
    assert.equals(0, #calls.files)
  end)
end)
