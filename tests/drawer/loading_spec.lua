-- Specs for the drawer's inline loading indicator: the shared single-line
-- renderer (line_for), the targeted single-line repaint the spinner drives, and
-- the connect/introspect lifecycle around the `loading` marker. Uses dependency
-- injection (state.new + an injected connector) -- no real databases except the
-- guarded sqlite end-to-end, which pends without the binary.

local drawer_mod = require('dadbod-ui.drawer')
local ids = require('dadbod-ui.drawer.ids')
local state = require('dadbod-ui.state')
local notifications = require('dadbod-ui.notifications')
local h = require('helper')

-- Offline connector; the async_connector stub (not covered by the shared helper)
-- mirrors the non-blocking connect path `expand_db` uses so specs never dispatch
-- a real probe. Individual specs override it to simulate success/failure/latency.
local function make_drawer(g_dbs, overrides)
  local d = h.make_drawer({ g_dbs = g_dbs, config = overrides, connector = 'offline' })
  d.async_connector = function(_, on_result)
    vim.schedule(function()
      on_result(true, '')
    end)
  end
  return d
end

describe('drawer loading: line_for', function()
  local d
  before_each(function()
    h.clean_ui()
  end)
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('produces a line identical to a full paint for every node type', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    d:open()
    local entry = h.entry_named(d, 'dev')
    -- exercise several node kinds at once: db, sections, schema, table, help
    d:set_expanded(ids.db(entry.key_name), true)
    d:set_expanded(ids.section(entry.key_name, 'schemas'), true)
    d:set_expanded(ids.schema(entry.key_name, 'public'), true)
    entry.schemas.list = { 'public' }
    entry.schemas.items = { public = { 'users' } }
    d:render()
    local rendered = h.buf_lines(d.bufnr)
    assert.is_true(#rendered > 4)
    for i, node in ipairs(d.content) do
      assert.equals(rendered[i], drawer_mod._line_for(node))
    end
  end)
end)

describe('drawer loading: repaint_db_node', function()
  local d
  before_each(function()
    h.clean_ui()
  end)
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('appends the frame to exactly the db line, locating it by key_name', function()
    d = make_drawer({ a = 'postgres://h/a', b = 'postgres://h/b' })
    d:open()
    local before = h.buf_lines(d.bufnr)
    local entry_b = h.entry_named(d, 'b')
    entry_b.loading = true
    d:repaint_db_node(entry_b.key_name, '@@')
    local after = h.buf_lines(d.bufnr)
    -- the matching db line gained a trailing frame; its leading icon + name stay
    local changed = {}
    for i = 1, math.max(#before, #after) do
      if before[i] ~= after[i] then
        changed[#changed + 1] = i
      end
    end
    assert.equals(1, #changed) -- exactly one line touched
    assert.equals(before[changed[1]] .. ' @@', after[changed[1]])
  end)

  it('leaves the buffer untouched for an unknown / not-loading key', function()
    d = make_drawer({ a = 'postgres://h/a' })
    d:open()
    local before = h.buf_lines(d.bufnr)
    d:repaint_db_node('does-not-exist', '@@')
    assert.same(before, h.buf_lines(d.bufnr))
    -- a known connection that is not loading renders no frame either
    d:repaint_db_node(h.entry_named(d, 'a').key_name, '@@')
    assert.same(before, h.buf_lines(d.bufnr))
  end)

  it('keeps the db line highlighted after a repaint (does not go uncolored)', function()
    local highlights = require('dadbod-ui.highlights')
    d = make_drawer({ a = 'postgres://h/a' })
    d:open()
    local entry = h.entry_named(d, 'a')
    -- find the db line index
    local idx
    for i, node in ipairs(d.content) do
      if node.type == 'db' and node.key_name == entry.key_name then
        idx = i - 1
        break
      end
    end
    assert.is_number(idx)
    entry.loading = true
    d:repaint_db_node(entry.key_name, '@@')
    -- the icon (at least) is re-highlighted as an extmark on that line
    local marks = vim.api.nvim_buf_get_extmarks(d.bufnr, highlights.NS, { idx, 0 }, { idx, -1 }, {})
    assert.is_true(#marks > 0)
  end)
end)

describe('drawer loading: lifecycle marker', function()
  local d
  before_each(function()
    h.clean_ui()
  end)
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('keeps the fold icon and trails a spinner while the entry is loading', function()
    local spinners = require('dadbod-ui.spinners')
    d = make_drawer({ dev = 'postgres://h/dev' })
    d:open()
    local idle = h.buf_lines(d.bufnr)[1] -- fold icon + name, no trailer
    local entry = h.entry_named(d, 'dev')
    entry.loading = true
    d:render()
    -- same leading fold icon + name, with the connection spinner (dots) appended
    assert.equals(idle .. ' ' .. spinners.dots[1], h.buf_lines(d.bufnr)[1])
  end)

  it('a connect error clears the marker, shows the error icon, and still notifies', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    d.async_connector = function(_, on_result)
      vim.schedule(function()
        on_result(false, 'boom')
      end)
    end
    d:open()
    local entry = h.entry_named(d, 'dev')
    d:set_expanded(ids.db(entry.key_name), true)
    d:introspect():expand_db(entry)
    vim.wait(1000, function()
      return entry.conn_tried
    end)
    assert.is_falsy(entry.loading)
    assert.is_truthy(entry.conn_error and entry.conn_error ~= '')
    d:render()
    assert.is_true(h.has_line(d.bufnr, d.icons.connection_error))
    assert.is_truthy(notifications.get_last_msg():find('Error connecting'))
  end)

  it('does not emit a "Connecting..." notification on expand', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    d.async_connector = function(_, on_result)
      vim.schedule(function()
        on_result(true, 'postgres://h/dev')
      end)
    end
    d:open()
    local entry = h.entry_named(d, 'dev')
    d:set_expanded(ids.db(entry.key_name), true)
    d:introspect():expand_db(entry)
    vim.wait(1000, function()
      return entry.conn_tried
    end)
    -- the only connection notification is the success line, never "Connecting..."
    assert.is_nil(notifications.get_last_msg():find('Connecting to db'))
  end)
end)

describe('drawer loading: sqlite end-to-end (guarded)', function()
  local d
  before_each(function()
    h.clean_ui()
  end)
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('clears the marker and shows the ok icon once tables land', function()
    local url = h.sqlite_db('CREATE TABLE contacts(id INTEGER, name TEXT);')
    if not url then
      return pending('sqlite3 not installed')
    end
    d = make_drawer({ qa = url })
    d.async_connector = require('dadbod-ui.bridge').connect_async
    d:open()
    local entry = h.entry_named(d, 'qa')
    d:set_expanded(ids.db(entry.key_name), true)
    d:introspect():expand_db(entry)
    local ok = vim.wait(3000, function()
      return not entry.loading and #entry.tables > 0
    end, 25)
    assert.is_true(ok, 'expected tables to load and the loading marker to clear')
    assert.is_true(state.is_connected(entry))
    d:render()
    assert.is_true(h.has_line(d.bufnr, d.icons.connection_ok))
  end)
end)
