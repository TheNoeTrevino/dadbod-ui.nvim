-- Specs for opening query buffers (M7): the New query buffer, table-helper
-- buffers with placeholder substitution, the buffer-local contract, and the
-- Buffers drawer section. No DB binary is needed -- the connector is stubbed and
-- nothing is executed here (execution is covered in dbout_spec).

local drawer_mod = require('dadbod-ui.drawer')
local ids = require('dadbod-ui.drawer.ids')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')

-- A drawer over an instance seeded with injected connections. The connector is
-- stubbed to echo the url back, so entries "connect" offline and b:db is set.
local function make_drawer(g_dbs, overrides)
  local cfg = config.resolve(
    vim.tbl_extend('force', { save_location = '/tmp/dbui_query', drawer = { show_help = false } }, overrides or {})
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

local function lines(d)
  return vim.api.nvim_buf_get_lines(d.bufnr, 0, -1, false)
end

local function has_line(d, pattern)
  for _, line in ipairs(lines(d)) do
    if line:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

describe('query buffers: open', function()
  local d
  local query_bufs = {}

  before_each(function()
    require('helper').clean_ui()
  end)

  after_each(function()
    for _, b in ipairs(query_bufs) do
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
    query_bufs = {}
    if d then
      d:close()
      d = nil
    end
  end)

  it('opens an empty New query buffer with the b:dbui_* contract', function()
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' })
    d:open()
    local entry = entry_named(d, 'qa')
    d:query():open({ type = 'query', key_name = entry.key_name }, 'edit')
    query_bufs[#query_bufs + 1] = vim.api.nvim_get_current_buf()

    assert.equals(entry.filetype, vim.bo.filetype)
    assert.equals('', vim.api.nvim_buf_get_lines(0, 0, -1, false)[1])
    assert.equals(entry.key_name, vim.b.dbui_db_key_name)
    assert.equals('', vim.b.dbui_table_name)
    assert.equals('', vim.b.dbui_schema_name)
    assert.equals(entry.conn, vim.b.db)
  end)

  it('pre-fills a table List helper buffer and sets the table name', function()
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' })
    d:open()
    local entry = entry_named(d, 'qa')
    d:query():open({
      type = 'table_helper',
      key_name = entry.key_name,
      table = 'contacts',
      schema = '',
      label = 'List',
      content = entry.table_helpers.List,
    }, 'edit')
    query_bufs[#query_bufs + 1] = vim.api.nvim_get_current_buf()

    assert.equals('SELECT * from "contacts" LIMIT 200;', vim.api.nvim_buf_get_lines(0, 0, -1, false)[1])
    assert.equals('contacts', vim.b.dbui_table_name)
  end)

  it('surfaces a dadbod execute error as a notification, not a crash', function()
    local bridge = require('dadbod-ui.bridge')
    local notifications = require('dadbod-ui.notifications')

    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' })
    d:open()
    local entry = entry_named(d, 'qa')
    d:query():open({ type = 'query', key_name = entry.key_name }, 'edit')
    query_bufs[#query_bufs + 1] = vim.api.nvim_get_current_buf()

    local saved = bridge.execute_buffer
    bridge.execute_buffer = function()
      error('Vim(echoerr):DB: Query already running for this tab', 0)
    end
    local ran_ok = pcall(function()
      d:query():execute_query()
    end)
    bridge.execute_buffer = saved

    assert.is_true(ran_ok) -- no crash bubbled up
    assert.equals('DB: Query already running for this tab', notifications.get_last_msg())
  end)

  it('registers the opened buffer under the Buffers section', function()
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' })
    d:open()
    local entry = entry_named(d, 'qa')
    d:query():open({ type = 'query', key_name = entry.key_name }, 'edit')
    query_bufs[#query_bufs + 1] = vim.api.nvim_get_current_buf()

    assert.equals(1, #entry.buffers.list)
    assert.is_true(d:is_expanded(ids.section(entry.key_name, 'buffers')))
    d:set_expanded(ids.db(entry.key_name), true)
    d:render()
    assert.is_true(has_line(d, 'Buffers (1)'))
  end)
end)

describe('query buffers: filename extension', function()
  local d

  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('names a New query buffer with the adapter query-input extension', function()
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' })
    local entry = entry_named(d, 'qa')
    assert.equals('sql', entry.extension)
    local name = d:query():generate_buffer_name(entry, { label = '', filetype = entry.filetype })
    -- <slug(name-query)>-<time>.sql -- a real .sql file so formatters/linters attach.
    assert.matches('qa%-query%-[%d%-]+%.sql$', name)
  end)

  it('names a table-helper buffer with the extension too', function()
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' })
    local entry = entry_named(d, 'qa')
    local name = d:query()
      :generate_buffer_name(entry, { table = 'contacts', label = 'List', filetype = entry.filetype })
    assert.matches('qa%-contacts%-List%-[%d%-]+%.sql$', name)
  end)

  it('uses the extension from the adapter, not a hardcoded sql (mysql -> sql ext, mysql filetype)', function()
    d = make_drawer({ my = 'mysql://h/shop' })
    local entry = entry_named(d, 'my')
    -- mysql's query-input extension is sql; its filetype is the distinct `mysql`.
    assert.equals('sql', entry.extension)
    assert.equals('mysql', entry.filetype)
    local name = d:query():generate_buffer_name(entry, { label = '', filetype = entry.filetype })
    assert.matches('%.sql$', name)
  end)

  it('sets the buffer filetype to entry.filetype even with a .sql name', function()
    d = make_drawer({ my = 'mysql://h/shop' })
    d:open()
    local entry = entry_named(d, 'my')
    d:query():open({ type = 'query', key_name = entry.key_name }, 'edit')
    local bufnr = vim.api.nvim_get_current_buf()
    -- The explicit setlocal filetype= stays authoritative over the .sql name's
    -- own detection (which would give `sql`).
    assert.equals('mysql', vim.bo.filetype)
    assert.matches('%.sql$', vim.api.nvim_buf_get_name(bufnr))
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end)

  it('respects buffer_name_generator without forcing an extension', function()
    d = make_drawer({ qa = 'sqlite:/tmp/qa.db' }, {
      buffer_name_generator = function()
        return 'custom-name'
      end,
    })
    local entry = entry_named(d, 'qa')
    local name = d:query():generate_buffer_name(entry, { label = '', filetype = entry.filetype })
    assert.matches('qa%-custom%-name$', name)
    assert.is_nil(name:match('%.sql$'))
  end)
end)
