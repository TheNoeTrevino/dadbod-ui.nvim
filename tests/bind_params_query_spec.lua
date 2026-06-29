-- Specs for the bind-parameter execute flow in dadbod-ui.query (M9): prompting,
-- persistence in b:dbui_bind_params, re-run without re-prompt, cancellation, and
-- the <Leader>E edit flow. The engine is stubbed (bridge functions swapped out),
-- so no DB binary is required -- we assert on what would be sent, not on rows.

local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')
local bridge = require('dadbod-ui.bridge')

local function make_drawer(overrides)
  local cfg = config.resolve(vim.tbl_extend('force', { save_location = '/tmp/dbui_bp', show_help = false }, overrides or {}))
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

describe('bind params: execute flow', function()
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

  it('runs the whole buffer directly when there are no placeholders', function()
    d = make_drawer()
    open_query({ 'SELECT 1' })
    d:query():execute_query()
    assert.equals(1, calls.buffer)
    assert.equals(0, #calls.files)
  end)

  it('runs a visual selection from a temp file (no marks, no %DB)', function()
    d = make_drawer()
    open_query({ 'SELECT 1', 'SELECT 2' })
    -- select the first line; leaving visual sets '<'/'>' so get_lines reads it
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd('normal! V')
    vim.cmd('normal! \27')
    d:query():execute_query(true)
    assert.equals(0, calls.buffer) -- never goes through %DB
    assert.same({ { 'SELECT 1' } }, calls.files)
    assert.equals(entry_named(d, 'qa').conn, calls.last_url)
  end)

  it('prompts for a placeholder, persists it, and runs the substituted query', function()
    d = make_drawer()
    open_query({ 'SELECT * FROM contacts WHERE id = :id' })

    local prompts = {}
    d:query().input = function(opts, on_confirm)
      table.insert(prompts, opts.prompt)
      on_confirm('5')
    end
    d:query():execute_query()

    assert.equals(1, #prompts)
    -- keys are the full placeholder text (':id'), matching the b:dbui_bind_params contract
    assert.same({ [':id'] = '5' }, vim.b[query_buf].dbui_bind_params)
    assert.equals(0, calls.buffer)
    assert.same({ { 'SELECT * FROM contacts WHERE id = 5' } }, calls.files)
    -- execution targets the captured connection url, not the current buffer's b:db
    assert.equals(entry_named(d, 'qa').conn, calls.last_url)
  end)

  it('quotes a string value and escapes embedded quotes', function()
    d = make_drawer()
    open_query({ 'WHERE name = :name' })
    d:query().input = function(_, on_confirm)
      on_confirm("O'Brien")
    end
    d:query():execute_query()
    assert.same({ { "WHERE name = 'O''Brien'" } }, calls.files)
  end)

  it('does not re-prompt on a second run with the value already stored', function()
    d = make_drawer()
    open_query({ 'WHERE id = :id' })

    local count = 0
    d:query().input = function(_, on_confirm)
      count = count + 1
      on_confirm('7')
    end
    d:query():execute_query()
    d:query():execute_query()

    assert.equals(1, count) -- prompted only the first time
    assert.equals(2, #calls.files) -- but executed both times
  end)

  it('aborts without executing or persisting when a prompt is cancelled', function()
    d = make_drawer()
    open_query({ 'SELECT :a, :b' })

    local seen = 0
    d:query().input = function(_, on_confirm)
      seen = seen + 1
      if seen == 1 then
        on_confirm('x') -- answer the first
      else
        on_confirm(nil) -- cancel the second
      end
    end
    d:query():execute_query()

    assert.equals(0, #calls.files) -- nothing executed
    assert.equals(0, calls.buffer)
    -- nothing persisted: a partial set must not leak into the contract
    local stored = vim.b[query_buf].dbui_bind_params
    assert.is_true(stored == nil or type(stored) ~= 'table' or vim.tbl_isempty(stored))
  end)

  it('honors a custom bind_param_pattern', function()
    d = make_drawer({ bind_param_pattern = '\\$\\d\\+' })
    open_query({ 'WHERE a = $1' })
    d:query().input = function(opts, on_confirm)
      assert.is_truthy(opts.prompt:find('$1', 1, true))
      on_confirm('9')
    end
    d:query():execute_query()
    assert.same({ { 'WHERE a = 9' } }, calls.files)
  end)
end)

describe('bind params: edit', function()
  local d, query_buf

  after_each(function()
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

  it('reports when there is nothing to edit', function()
    local notify = require('dadbod-ui.notifications')
    d = make_drawer()
    open_query({ 'SELECT 1' })
    d:query():edit_bind_parameters()
    assert.equals('No bind parameters to edit.', notify.get_last_msg())
  end)

  it('offers a placeholder detected in the buffer before any execute', function()
    d = make_drawer()
    open_query({ 'WHERE id = :id' }) -- never executed: nothing stored yet

    local default_seen = '<unset>'
    d:query().input = function(opts, on_confirm)
      default_seen = opts.default
      on_confirm('5')
    end
    d:query():edit_bind_parameters()

    assert.is_nil(default_seen) -- not provided yet -> no prefill
    assert.same({ [':id'] = '5' }, vim.b[query_buf].dbui_bind_params)
  end)

  it('pre-filled values are not re-prompted on the next execute', function()
    local bridge = require('dadbod-ui.bridge')
    local saved = { ef = bridge.execute_file, ix = bridge.input_extension, cc = bridge.can_cancel }
    local files = {}
    bridge.execute_file = function(file)
      table.insert(files, vim.fn.readfile(file))
    end
    bridge.input_extension = function()
      return 'sql'
    end
    bridge.can_cancel = function()
      return false
    end

    d = make_drawer()
    open_query({ 'WHERE id = :id' })
    -- pre-fill via edit, then execute
    d:query().input = function(_, on_confirm)
      on_confirm('5')
    end
    d:query():edit_bind_parameters()

    local prompted = false
    d:query().input = function(_, on_confirm)
      prompted = true
      on_confirm('nope')
    end
    d:query():execute_query()

    bridge.execute_file, bridge.input_extension, bridge.can_cancel = saved.ef, saved.ix, saved.cc
    assert.is_false(prompted) -- already provided, so no prompt
    assert.same({ { 'WHERE id = 5' } }, files)
  end)

  it('edits the single stored parameter directly (no picker)', function()
    d = make_drawer()
    open_query({ 'WHERE id = :id' })
    vim.b[query_buf].dbui_bind_params = { [':id'] = '1' }

    local default_seen
    d:query().input = function(opts, on_confirm)
      default_seen = opts.default
      on_confirm('2')
    end
    d:query():edit_bind_parameters()

    assert.equals('1', default_seen) -- prefilled with the current value
    assert.same({ [':id'] = '2' }, vim.b[query_buf].dbui_bind_params)
  end)

  it('uses the picker to choose among several parameters', function()
    d = make_drawer()
    open_query({ 'WHERE a = :a AND b = :b' })
    vim.b[query_buf].dbui_bind_params = { [':a'] = '1', [':b'] = '2' }

    d:query().select = function(items, _, on_choice)
      assert.same({ ':a', ':b' }, items) -- sorted names
      on_choice(':b')
    end
    d:query().input = function(_, on_confirm)
      on_confirm('99')
    end
    d:query():edit_bind_parameters()

    assert.same({ [':a'] = '1', [':b'] = '99' }, vim.b[query_buf].dbui_bind_params)
  end)

  it('renders an unanswered detected param as "Not provided" in the picker', function()
    d = make_drawer()
    open_query({ 'WHERE a = :a AND b = :b' })
    vim.b[query_buf].dbui_bind_params = { [':a'] = '1' } -- :b detected but unanswered

    local rendered
    d:query().select = function(items, opts, on_choice)
      rendered = vim.tbl_map(opts.format_item, items)
      on_choice(nil)
    end
    d:query():edit_bind_parameters()

    assert.same({ ':a = 1', ':b = Not provided' }, rendered)
  end)

  it('leaves the value unchanged when the edit is cancelled', function()
    d = make_drawer()
    open_query({ 'WHERE id = :id' })
    vim.b[query_buf].dbui_bind_params = { [':id'] = '1' }
    d:query().input = function(_, on_confirm)
      on_confirm(nil)
    end
    d:query():edit_bind_parameters()
    assert.same({ [':id'] = '1' }, vim.b[query_buf].dbui_bind_params)
  end)
end)
