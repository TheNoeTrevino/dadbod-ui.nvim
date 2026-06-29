-- Specs for result (.dbout) handling (M7): recording executed results under the
-- Query results section, sort order, and a guarded end-to-end execute-on-save
-- that runs real SQL through dadbod and renders the rows in a .dbout buffer.

local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')
local dbout = require('dadbod-ui.dbout')

local function make_drawer(g_dbs, overrides)
  local cfg = config.resolve(vim.tbl_extend('force', { save_location = '/tmp/dbui_dbout', show_help = false }, overrides or {}))
  local instance = state.new(cfg):populate({ env = {}, g_dbs = g_dbs or {}, file_entries = {} })
  local d = drawer_mod.new(instance)
  d.connector = function(url)
    return url
  end
  return d
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

describe('dbout: Query results section', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('records an executed result and shows the Query results header', function()
    d = make_drawer()
    d:open()
    dbout.save_dbout('/tmp/dbui_dbout/12.dbout')
    assert.is_not_nil(d.instance.dbout_list['/tmp/dbui_dbout/12.dbout'])
    assert.is_true(has_line(d, 'Query results (1)'))
  end)

  it('lists result files under the expanded section, sorted ascending', function()
    d = make_drawer()
    d:open()
    dbout.save_dbout('/tmp/dbui_dbout/30.dbout')
    dbout.save_dbout('/tmp/dbui_dbout/2.dbout')
    d.show_dbout_list = true
    d:render()
    local body = lines(d)
    local i2, i30
    for idx, line in ipairs(body) do
      if line:find('2.dbout', 1, true) then
        i2 = idx
      end
      if line:find('30.dbout', 1, true) then
        i30 = idx
      end
    end
    assert.is_not_nil(i2)
    assert.is_not_nil(i30)
    assert.is_true(i2 < i30) -- 2 before 30 (numeric, ascending)
  end)

  it('sorts descending when dbout_list_sort is desc', function()
    d = make_drawer(nil, { dbout_list_sort = 'desc' })
    d:open()
    assert.is_true(dbout.sort_dbout('/x/30.dbout', '/x/2.dbout'))
    assert.is_false(dbout.sort_dbout('/x/2.dbout', '/x/30.dbout'))
  end)
end)

describe('dbout: execute on save (sqlite)', function()
  local d
  local fixture = '/tmp/dbui_dbout_qa.db'
  local query_bufs = {}

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

  it('runs the buffer on :w and renders rows in a .dbout buffer', function()
    if vim.fn.executable('sqlite3') ~= 1 then
      return pending('sqlite3 not installed')
    end
    d = make_drawer({ qa = 'sqlite:' .. fixture }, { execute_on_save = true })
    d.connector = require('dadbod-ui.bridge').connect -- real connection
    d:open()
    local entry
    for _, record in ipairs(d.instance.dbs_list) do
      if record.name == 'qa' then
        entry = d.instance.dbs[record.key_name]
      end
    end
    d:query():open({ type = 'query', key_name = entry.key_name }, 'edit')
    query_bufs[#query_bufs + 1] = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'SELECT name FROM contacts ORDER BY name;' })
    vim.cmd('silent write')

    local function dbout_has(text)
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(b):match('%.dbout$') then
          for _, line in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
            if line:find(text, 1, true) then
              return true
            end
          end
        end
      end
      return false
    end

    local ok = vim.wait(5000, function()
      return dbout_has('ada')
    end, 50)
    assert.is_true(ok, 'expected the .dbout buffer to contain the query rows')
    assert.is_true(next(d.instance.dbout_list) ~= nil)
  end)
end)
