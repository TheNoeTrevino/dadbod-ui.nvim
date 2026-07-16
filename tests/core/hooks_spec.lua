-- Specs for the user-configurable hooks system (issue #20): the pure dispatch
-- module (run/transform, isolation, string narrowing) plus the six wired hooks
-- (connect pre/post, execute pre/post, cancel pre/post). Everything is driven by
-- dependency injection -- an injected connector spy, stubbed bridge functions,
-- and config carrying spy hooks -- so no live DB is touched.

local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')
local hooks = require('dadbod-ui.hooks')
local notifications = require('dadbod-ui.notifications')
local bridge = require('dadbod-ui.bridge')
local dbout = require('dadbod-ui.dbout')

local function make_drawer(g_dbs, overrides)
  local cfg = config.resolve(
    vim.tbl_extend('force', { save_location = '/tmp/dbui_hooks', drawer = { show_help = false } }, overrides or {})
  )
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

-- The dispatch module in isolation -----------------------------------------

describe('hooks: run', function()
  it('returns nil when the named hook is not configured', function()
    assert.is_nil(hooks.run({ hooks = {} }, 'on_connect', {}))
  end)

  it('returns nil when there is no hooks table at all', function()
    assert.is_nil(hooks.run({}, 'on_connect', {}))
  end)

  it('calls the hook with the event and returns its value', function()
    local seen
    local cfg = {
      hooks = {
        on_connect = function(e)
          seen = e
          return 'ret'
        end,
      },
    }
    assert.equals('ret', hooks.run(cfg, 'on_connect', { url = 'u' }))
    assert.equals('u', seen.url)
  end)

  it('catches a throwing hook, notifies, and returns nil (never propagates)', function()
    local cfg = {
      hooks = {
        on_connect = function()
          error('boom')
        end,
      },
    }
    assert.is_nil(hooks.run(cfg, 'on_connect', {}))
    assert.is_truthy(notifications.get_last_msg():find('on_connect'))
  end)
end)

describe('hooks: transform', function()
  it('returns a string result verbatim', function()
    local cfg = {
      hooks = {
        on_connect = function()
          return 'rewritten'
        end,
      },
    }
    assert.equals('rewritten', hooks.transform(cfg, 'on_connect', {}))
  end)

  it('narrows a non-string return to nil (unchanged)', function()
    local cfg = {
      hooks = {
        on_connect = function()
          return 42
        end,
      },
    }
    assert.is_nil(hooks.transform(cfg, 'on_connect', {}))
  end)

  it('returns nil when the hook is absent', function()
    assert.is_nil(hooks.transform({ hooks = {} }, 'on_connect', {}))
  end)

  it('returns nil when the hook throws', function()
    local cfg = {
      hooks = {
        on_connect = function()
          error('nope')
        end,
      },
    }
    assert.is_nil(hooks.transform(cfg, 'on_connect', {}))
  end)
end)

-- Config surface ------------------------------------------------------------

describe('hooks: config', function()
  it('defaults to an empty hooks table', function()
    assert.same({}, config.resolve().hooks)
  end)

  it('keeps hook functions through the deep merge', function()
    local fn = function() end
    local cfg = config.resolve({ hooks = { on_connect = fn } })
    assert.equals(fn, cfg.hooks.on_connect)
  end)
end)

-- Connect path (on_connect / on_connect_post) -------------------------------
describe('hooks: on_connect (url rewrite)', function()
  local d
  after_each(function()
    if d then
      pcall(function()
        d:close()
      end)
      d = nil
    end
  end)

  -- Assertions are relative to entry.url (dadbod normalizes the raw url on
  -- discovery, e.g. postgres -> postgresql), so they test the hook threading,
  -- not the engine's url spelling.

  it('no hooks: connect is unchanged and uses the original url', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    local got
    d.connector = function(url)
      got = url
      return url
    end
    local entry = entry_named(d, 'dev')
    d:introspect():connect(entry)
    assert.equals(entry.url, got)
    assert.equals(entry.url, entry.conn)
  end)

  it('rewrites the connection url before connecting (password use case)', function()
    d = make_drawer({ dev = 'sqlite:/tmp/qa.db' }, {
      hooks = {
        on_connect = function(e)
          -- simulate swapping a placeholder for a secret fetched from a manager
          return e.url .. '?password=secret'
        end,
      },
    })
    local got
    d.connector = function(url)
      got = url
      return url
    end
    local entry = entry_named(d, 'dev')
    local rewritten = entry.url .. '?password=secret'
    d:introspect():connect(entry)
    -- the connector saw the rewritten url, and the live handle downstream
    -- execution/introspection use is the rewritten (authed) one.
    assert.equals(rewritten, got)
    assert.equals(rewritten, entry.conn)
  end)

  it('uses the original url when on_connect returns nil', function()
    d = make_drawer({ dev = 'postgres://h/dev' }, {
      hooks = {
        on_connect = function()
          return nil
        end,
      },
    })
    local got
    d.connector = function(url)
      got = url
      return url
    end
    local entry = entry_named(d, 'dev')
    d:introspect():connect(entry)
    assert.equals(entry.url, got)
  end)

  it('uses the original url when on_connect returns a non-string', function()
    d = make_drawer({ dev = 'postgres://h/dev' }, {
      hooks = {
        on_connect = function()
          return { not_a = 'string' }
        end,
      },
    })
    local got
    d.connector = function(url)
      got = url
      return url
    end
    local entry = entry_named(d, 'dev')
    d:introspect():connect(entry)
    assert.equals(entry.url, got)
  end)

  it('isolates a throwing on_connect; connect proceeds with the original url', function()
    d = make_drawer({ dev = 'postgres://h/dev' }, {
      hooks = {
        on_connect = function()
          error('secret fetch failed')
        end,
      },
    })
    local got
    d.connector = function(url)
      got = url
      return url
    end
    local entry = entry_named(d, 'dev')
    d:introspect():connect(entry)
    assert.equals(entry.url, got)
    assert.equals(entry.url, entry.conn)
  end)
end)

describe('hooks: on_connect_post', function()
  local d
  after_each(function()
    if d then
      pcall(function()
        d:close()
      end)
      d = nil
    end
  end)

  it('fires after a successful connect with the outcome and handle', function()
    local ev
    d = make_drawer({ dev = 'postgres://h/dev' }, {
      hooks = {
        on_connect_post = function(e)
          ev = e
        end,
      },
    })
    local entry = entry_named(d, 'dev')
    d:introspect():connect(entry)
    assert.is_true(ev.success)
    assert.equals(entry.conn, ev.conn)
    assert.is_nil(ev.error)
  end)

  it('fires with the error when the connect fails', function()
    local ev
    d = make_drawer({ dev = 'postgres://h/dev' }, {
      hooks = {
        on_connect_post = function(e)
          ev = e
        end,
      },
    })
    d.connector = function()
      error('connection refused')
    end
    d:introspect():connect(entry_named(d, 'dev'))
    assert.is_false(ev.success)
    assert.is_truthy(ev.error)
    assert.is_nil(ev.conn)
  end)
end)

-- Execute pre (on_execute_query) --------------------------------------------
describe('hooks: on_execute_query', function()
  local d, query_buf, saved

  before_each(function()
    saved = {
      execute_buffer = bridge.execute_buffer,
      execute_lines = bridge.execute_lines,
      execute_file = bridge.execute_file,
      execute = bridge.execute,
      can_cancel = bridge.can_cancel,
    }
    bridge.execute_buffer = function() end
    bridge.execute_lines = function() end
    bridge.execute_file = function() end
    bridge.execute = function() end
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
      pcall(function()
        d:close()
      end)
      d = nil
    end
  end)

  it('fires before dispatch with the sql, url, bufnr and visual flag', function()
    local ev
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' }, {
      hooks = {
        on_execute_query = function(e)
          ev = e
        end,
      },
    })
    d:open()
    local entry = entry_named(d, 'qa')
    d:query():open({ type = 'query', key_name = entry.key_name }, 'edit')
    query_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'SELECT 1;' })
    d:query():execute_query(false)
    assert.is_table(ev)
    assert.same({ 'SELECT 1;' }, ev.sql)
    assert.equals(query_buf, ev.bufnr)
    assert.equals(entry.key_name, ev.key_name)
    assert.equals(entry.conn, ev.url)
    assert.is_false(ev.is_visual)
  end)
end)

-- Execute post (on_execute_query_post) --------------------------------------

describe('hooks: on_execute_query_post', function()
  local d, out_buf

  after_each(function()
    if out_buf then
      pcall(vim.api.nvim_buf_delete, out_buf, { force = true })
      out_buf = nil
    end
    if d then
      pcall(function()
        d:close()
      end)
      d = nil
    end
  end)

  it('fires with a rows accessor, the query, runtime and exit_status', function()
    local ev
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' }, {
      hooks = {
        on_execute_query_post = function(e)
          ev = e
        end,
      },
    })
    -- Attach the drawer directly so dbout reads ITS config (with the hook)
    -- without opening the drawer window (which would trigger a render on the
    -- result-buffer read path, unrelated to what we're testing here).
    dbout.attach(d)

    local out = vim.fn.tempname() .. '.dbout'
    local inp = vim.fn.tempname()
    vim.fn.writefile({ 'SELECT * FROM contacts;' }, inp)
    -- A plain loaded buffer named for the output file (no BufReadPost autocmd),
    -- carrying the b:db dict dadbod leaves on a reloaded result buffer.
    out_buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(out_buf, out)
    vim.api.nvim_buf_set_lines(out_buf, 0, -1, false, { ' id | name ', '----+------', '  1 | ada', '(1 row)' })
    vim.b[out_buf].db = { input = inp, runtime = '0.020', exit_status = '0', db_url = 'sqlite:/tmp/qa.db' }

    dbout._on_post(out)

    assert.is_table(ev)
    assert.equals(out, ev.output_file)
    assert.same({ 'SELECT * FROM contacts;' }, ev.query)
    assert.equals(0, ev.exit_status)
    assert.equals(0.02, ev.runtime)
    -- the rows accessor reads the landed result (the "save results elsewhere" use case)
    local rows = ev.rows()
    assert.is_truthy(vim.tbl_contains(rows, '  1 | ada'))
  end)
end)

-- Cancel (on_cancel_query / on_cancel_query_post) ---------------------------

describe('hooks: cancel', function()
  local d, query_buf, saved

  before_each(function()
    saved = { can_cancel = bridge.can_cancel, cancel = bridge.cancel }
  end)

  after_each(function()
    bridge.can_cancel = saved.can_cancel
    bridge.cancel = saved.cancel
    if query_buf then
      pcall(vim.api.nvim_buf_delete, query_buf, { force = true })
      query_buf = nil
    end
    if d then
      pcall(function()
        d:close()
      end)
      d = nil
    end
  end)

  it('fires pre -> cancel -> post when a query is cancellable', function()
    local order = {}
    bridge.can_cancel = function()
      return true
    end
    bridge.cancel = function(bufnr)
      order[#order + 1] = 'cancel:' .. tostring(bufnr)
    end
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' }, {
      hooks = {
        on_cancel_query = function()
          order[#order + 1] = 'pre'
        end,
        on_cancel_query_post = function()
          order[#order + 1] = 'post'
        end,
      },
    })
    d:open()
    local entry = entry_named(d, 'qa')
    d:query():open({ type = 'query', key_name = entry.key_name }, 'edit')
    query_buf = vim.api.nvim_get_current_buf()

    d:query():cancel_query()

    assert.same({ 'pre', 'cancel:' .. query_buf, 'post' }, order)
  end)

  it('fires no hooks when nothing is cancellable (can_cancel is false)', function()
    local fired = false
    bridge.can_cancel = function()
      return false
    end
    bridge.cancel = function()
      fired = true
    end
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' }, {
      hooks = {
        on_cancel_query = function()
          fired = true
        end,
        on_cancel_query_post = function()
          fired = true
        end,
      },
    })
    d:open()
    local entry = entry_named(d, 'qa')
    d:query():open({ type = 'query', key_name = entry.key_name }, 'edit')
    query_buf = vim.api.nvim_get_current_buf()

    d:query():cancel_query()
    assert.is_false(fired)
  end)
end)
