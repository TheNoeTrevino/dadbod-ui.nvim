-- Specs for the explain-tree wiring: the query-buffer verb (Query:explain_tree)
-- wraps the buffer SQL in the JSON EXPLAIN form and runs it through the
-- HEADLESS client path (bridge.run_many, never `:DB`), with the raw-output
-- argv folded in; the decoded plan opens in the tree window. api.explain_tree
-- surfaces the pre-flight errors. The engine is stubbed like explain_spec's
-- buffer-level suite -- no DB binary involved.

local api = require('dadbod-ui.api')
local bridge = require('dadbod-ui.bridge')
local config = require('dadbod-ui.config')
local drawer_mod = require('dadbod-ui.drawer')
local notifications = require('dadbod-ui.notifications')
local state = require('dadbod-ui.state')
local tree = require('dadbod-ui.explain.tree')

local PLAN_JSON = vim.json.encode({
  {
    Plan = {
      ['Node Type'] = 'Seq Scan',
      ['Relation Name'] = 'contacts',
      Alias = 'contacts',
      ['Startup Cost'] = 0.0,
      ['Total Cost'] = 12.0,
      ['Plan Rows'] = 100,
    },
    ['Planning Time'] = 0.1,
  },
})

describe('explain tree: query-buffer wiring', function()
  local d, query_bufs, saved_run_many, ran_specs, canned

  local function make_drawer(g_dbs)
    local cfg = config.resolve({ save_location = '/tmp/dbui_explain_wire', drawer = { show_help = false } })
    local instance = state.new(cfg):populate({ env = {}, g_dbs = g_dbs, file_entries = {} })
    local dr = drawer_mod.new(instance)
    dr.connector = function(url)
      return url
    end
    return dr
  end

  local function entry_named(dr, name)
    for _, record in ipairs(dr.instance.dbs_list) do
      if record.name == name then
        return dr.instance.dbs[record.key_name]
      end
    end
  end

  local function open_query_buffer(name, sql)
    d:open()
    local entry = entry_named(d, name)
    d:query():open({ type = 'query', key_name = entry.key_name }, 'edit')
    query_bufs[#query_bufs + 1] = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(sql, '\n'))
    return entry
  end

  before_each(function()
    require('helper').clean_ui()
    query_bufs, ran_specs, canned = {}, {}, nil
    saved_run_many = bridge.run_many
    -- Capture the headless command specs; feed back the canned client result.
    bridge.run_many = function(specs, on_done)
      vim.list_extend(ran_specs, specs)
      on_done({ canned })
    end
  end)
  after_each(function()
    bridge.run_many = saved_run_many
    tree.close()
    for _, b in ipairs(query_bufs) do
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
    if d then
      d:close()
      d = nil
    end
    vim.g.dbs = nil
    state.reset()
  end)

  it('runs the wrapped JSON explain headlessly and opens the tree', function()
    canned = { code = 0, stdout = PLAN_JSON, stderr = '' }
    d = make_drawer({ dev = 'postgres://u@h/dev' })
    local entry = open_query_buffer('dev', 'select * from contacts')
    entry.conn = entry.url -- a live connection (the connector is identity)
    d:query():explain_tree(false)

    assert.equals(1, #ran_specs)
    -- postgres is a filter-mode adapter: the SQL arrives on stdin, wrapped.
    assert.equals('EXPLAIN (FORMAT JSON) select * from contacts', ran_specs[1].stdin)
    -- The raw-output argv is folded into the client command.
    local cmd = table.concat(ran_specs[1].cmd, ' ')
    assert.is_truthy(cmd:match('%-%-no%-psqlrc'))
    assert.is_truthy(cmd:match('%-A'))

    local t = assert(tree.get())
    local lines = vim.api.nvim_buf_get_lines(t.bufnr, 0, -1, false)
    assert.is_truthy(lines[3]:match('Seq Scan on contacts'))
  end)

  it('uses the executing JSON form for analyze', function()
    canned = { code = 0, stdout = PLAN_JSON, stderr = '' }
    d = make_drawer({ dev = 'postgres://u@h/dev' })
    local entry = open_query_buffer('dev', 'delete from contacts')
    entry.conn = entry.url
    d:query():explain_tree(false, { analyze = true })
    assert.is_truthy(ran_specs[1].stdin:match('^BEGIN;'))
    assert.is_truthy(ran_specs[1].stdin:match('ROLLBACK;$'))
  end)

  it('surfaces the client error (stderr) and opens nothing', function()
    canned = { code = 3, stdout = '', stderr = 'ERROR:  relation "nope" does not exist' }
    d = make_drawer({ dev = 'postgres://u@h/dev' })
    local entry = open_query_buffer('dev', 'select * from nope')
    entry.conn = entry.url
    d:query():explain_tree(false)
    assert.is_nil(tree.get())
    assert.is_truthy(notifications.get_last_msg():match('relation "nope" does not exist'))
  end)

  it('rejects adapters without a structured plan format before running', function()
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' })
    local entry = open_query_buffer('qa', 'select 1')
    entry.conn = entry.url
    d:query():explain_tree(false)
    assert.equals(0, #ran_specs)
    assert.is_truthy(notifications.get_last_msg():match('JSON explain plan is not supported'))
  end)

  it('requires a live connection', function()
    d = make_drawer({ dev = 'postgres://u@h/dev' })
    local entry = open_query_buffer('dev', 'select 1')
    entry.conn = nil
    d:query():explain_tree(false)
    assert.equals(0, #ran_specs)
    assert.is_truthy(notifications.get_last_msg():match('Not connected'))
  end)
end)

describe('explain tree: api pre-flight', function()
  after_each(function()
    vim.g.dbs = nil
    state.reset()
  end)

  it('reports an unknown connection', function()
    vim.g.dbs = { dev = 'postgres://u@h/dev' }
    state.setup({ save_location = '/tmp/dbui_explain_wire_api' })
    state.get()
    local ok, err = api.explain_tree('nope', 'select 1')
    assert.is_false(ok)
    assert.is_truthy(err and err:match('no connection named nope'))
  end)

  it('reports an adapter without a structured plan format', function()
    vim.g.dbs = { qa = 'sqlite:/tmp/qa.db' }
    state.setup({ save_location = '/tmp/dbui_explain_wire_api' })
    state.get()
    local ok, err = api.explain_tree('qa', 'select 1')
    assert.is_false(ok)
    assert.is_truthy(err and err:match('JSON explain plan is not supported'))
  end)
end)
