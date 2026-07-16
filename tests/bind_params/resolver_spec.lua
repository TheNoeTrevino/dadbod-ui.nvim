-- Specs for the `resolve_bind_params` config hook: a data-plane hook that supplies
-- bind-param values before dadbod-ui falls back to prompting. Lets users source
-- values from env / a vault / a fixed table. The engine is stubbed (bridge
-- functions swapped out), so we assert on what would be sent. Key behaviors:
-- resolved values skip the prompt and persist, partial resolution prompts only the
-- rest, a throwing hook degrades cleanly to prompting, and the hook is not called
-- when the query has no placeholders.

local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')
local bridge = require('dadbod-ui.bridge')

local function make_drawer(overrides)
  local cfg = config.resolve(
    vim.tbl_extend('force', { save_location = '/tmp/dbui_resolve', drawer = { show_help = false } }, overrides or {})
  )
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

describe('bind params: resolve_bind_params hook', function()
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

  it('uses resolved values without prompting, and persists them', function()
    d = make_drawer({
      hooks = {
        resolve_bind_params = function(_names, _known)
          return { [':id'] = '5' }
        end,
      },
    })
    open_query({ 'SELECT * FROM contacts WHERE id = :id' })
    local prompts = 0
    d:query().input = function(_opts, on_confirm)
      prompts = prompts + 1
      on_confirm('999') -- should never run: the hook already answered :id
    end
    d:query():execute_query()

    assert.equals(0, prompts)
    assert.same({ { 'SELECT * FROM contacts WHERE id = 5 LIMIT 200 OFFSET 0' } }, calls.files)
    assert.same({ [':id'] = '5' }, vim.b[query_buf].dbui_bind_params)
  end)

  it('prompts only for the params the hook did not resolve', function()
    d = make_drawer({
      hooks = {
        resolve_bind_params = function(_names, _known)
          return { [':a'] = '1' } -- leaves :b to the prompt
        end,
      },
    })
    open_query({ 'SELECT * FROM t WHERE a = :a AND b = :b' })
    local prompted = {}
    d:query().input = function(opts, on_confirm)
      table.insert(prompted, opts.prompt)
      on_confirm('2')
    end
    d:query():execute_query()

    assert.equals(1, #prompted)
    assert.is_truthy(prompted[1]:find(':b', 1, true))
    assert.same({ { 'SELECT * FROM t WHERE a = 1 AND b = 2 LIMIT 200 OFFSET 0' } }, calls.files)
  end)

  it('degrades to prompting when the hook throws', function()
    d = make_drawer({
      hooks = {
        resolve_bind_params = function(_names, _known)
          error('boom')
        end,
      },
    })
    open_query({ 'SELECT * FROM contacts WHERE id = :id' })
    local prompts = 0
    d:query().input = function(_opts, on_confirm)
      prompts = prompts + 1
      on_confirm('7')
    end
    d:query():execute_query()

    assert.equals(1, prompts)
    assert.same({ { 'SELECT * FROM contacts WHERE id = 7 LIMIT 200 OFFSET 0' } }, calls.files)
  end)

  it('is not called when the query has no placeholders', function()
    local called = false
    d = make_drawer({
      hooks = {
        resolve_bind_params = function(_names, _known)
          called = true
        end,
      },
    })
    open_query({ 'SELECT 1' })
    d:query():execute_query()

    assert.is_false(called)
    assert.same({ { 'SELECT 1 LIMIT 200 OFFSET 0' } }, calls.files)
  end)
end)
