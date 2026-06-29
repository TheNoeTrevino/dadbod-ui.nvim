-- Specs for the drawer's inline loading indicator: the shared single-line
-- renderer (line_for), the targeted single-line repaint the spinner drives, and
-- the connect/introspect lifecycle around the `loading` marker. Uses dependency
-- injection (state.new + an injected connector) -- no real databases except the
-- guarded sqlite end-to-end, which pends without the binary.

local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')
local notifications = require('dadbod-ui.notifications')

local function make_drawer(g_dbs, overrides)
  local cfg = config.resolve(vim.tbl_extend('force', { save_location = '/tmp/dbui_loading', show_help = false }, overrides or {}))
  local instance = state.new(cfg):populate({ env = {}, g_dbs = g_dbs, file_entries = {} })
  local d = drawer_mod.new(instance)
  d.connector = function()
    return ''
  end
  return d
end

local function lines(d)
  return vim.api.nvim_buf_get_lines(d.bufnr, 0, -1, false)
end

local function has_line(d, text)
  for _, line in ipairs(lines(d)) do
    if line:find(text, 1, true) then
      return true
    end
  end
  return false
end

local function entry_named(d, name)
  for _, record in ipairs(d.instance.dbs_list) do
    if record.name == name then
      return d.instance.dbs[record.key_name]
    end
  end
end

describe('drawer loading: line_for', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('produces a line identical to a full paint for every node type', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    d:open()
    local entry = entry_named(d, 'dev')
    -- exercise several node kinds at once: db, sections, schema, table, help
    entry.expanded = true
    entry.schemas.expanded = true
    entry.schemas.list = { 'public' }
    entry.schemas.items = {
      public = {
        expanded = true,
        tables = { expanded = true, list = { 'users' }, items = { users = { expanded = false } } },
      },
    }
    d:render()
    local rendered = lines(d)
    assert.is_true(#rendered > 4)
    for i, node in ipairs(d.content) do
      assert.equals(rendered[i], drawer_mod._line_for(node))
    end
  end)
end)

describe('drawer loading: repaint_db_node', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('appends the frame to exactly the db line, locating it by key_name', function()
    d = make_drawer({ a = 'postgres://h/a', b = 'postgres://h/b' })
    d:open()
    local before = lines(d)
    local entry_b = entry_named(d, 'b')
    d:repaint_db_node(entry_b.key_name, '@@')
    local after = lines(d)
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

  it('no-ops when the node is absent (collapsed away / unknown key)', function()
    d = make_drawer({ a = 'postgres://h/a' })
    d:open()
    local before = lines(d)
    d:repaint_db_node('does-not-exist', '@@')
    assert.same(before, lines(d))
  end)
end)

describe('drawer loading: lifecycle marker', function()
  local d
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
    local idle = lines(d)[1] -- fold icon + name, no trailer
    local entry = entry_named(d, 'dev')
    entry.loading = true
    d:render()
    -- same leading fold icon + name, with the connection spinner (dots) appended
    assert.equals(idle .. ' ' .. spinners.dots[1], lines(d)[1])
  end)

  it('a connect error clears the marker, shows the error icon, and still notifies', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    d.connector = function()
      error('boom')
    end
    d:open()
    local entry = entry_named(d, 'dev')
    entry.expanded = true
    d:introspect():expand_db(entry)
    vim.wait(1000, function()
      return entry.conn_tried
    end)
    assert.is_falsy(entry.loading)
    assert.is_truthy(entry.conn_error and entry.conn_error ~= '')
    d:render()
    assert.is_true(has_line(d, d.icons.connection_error))
    assert.is_truthy(notifications.get_last_msg():find('Error connecting'))
  end)

  it('does not emit a "Connecting..." notification on expand', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    d.connector = function()
      return 'postgres://h/dev'
    end
    d:open()
    local entry = entry_named(d, 'dev')
    entry.expanded = true
    d:introspect():expand_db(entry)
    vim.wait(1000, function()
      return entry.conn_tried
    end)
    -- the only connection notification is the success line, never "Connecting..."
    assert.is_nil(notifications.get_last_msg():find('Connecting to db'))
  end)
end)

describe('drawer loading: sqlite end-to-end (guarded)', function()
  local d, dir, db_path
  before_each(function()
    if vim.fn.executable('sqlite3') ~= 1 then
      return
    end
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    db_path = dir .. '/qa.db'
    vim.fn.system({ 'sqlite3', db_path, 'CREATE TABLE contacts(id INTEGER, name TEXT);' })
  end)
  after_each(function()
    if d then
      d:close()
      d = nil
    end
    if dir then
      vim.fn.delete(dir, 'rf')
      dir, db_path = nil, nil
    end
  end)

  it('clears the marker and shows the ok icon once tables land', function()
    if vim.fn.executable('sqlite3') ~= 1 then
      return pending('sqlite3 not installed')
    end
    d = make_drawer({ qa = 'sqlite:' .. db_path })
    d.connector = require('dadbod-ui.bridge').connect
    d:open()
    local entry = entry_named(d, 'qa')
    entry.expanded = true
    d:introspect():expand_db(entry)
    local ok = vim.wait(3000, function()
      return not entry.loading and #entry.tables.list > 0
    end, 25)
    assert.is_true(ok, 'expected tables to load and the loading marker to clear')
    assert.is_true(state.is_connected(entry))
    d:render()
    assert.is_true(has_line(d, d.icons.connection_ok))
  end)
end)
