-- Specs for result (.dbout) handling (M7): recording executed results under the
-- Query results section, sort order, and a guarded end-to-end execute-on-save
-- that runs real SQL through dadbod and renders the rows in a .dbout buffer.

local ids = require('dadbod-ui.drawer.ids')
local dbout = require('dadbod-ui.dbout')
local h = require('helper')

-- Shared across the Query results specs: the dbout entries are keyed by path, so
-- the drawer's save_location and the recorded result paths must agree.
local save_dir = h.tmp_dir()

-- Default 'echo' connector (returns the url) so entries "connect".
local function make_drawer(g_dbs, overrides)
  return h.make_drawer({
    g_dbs = g_dbs or {},
    config = vim.tbl_deep_extend('force', { save_location = save_dir }, overrides or {}),
  })
end

describe('dbout: Query results section', function()
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

  it('records an executed result and shows the Query results header', function()
    d = make_drawer()
    d:open()
    dbout.save_dbout(save_dir .. '/12.dbout')
    assert.is_not_nil(d.instance.dbout_list[save_dir .. '/12.dbout'])
    assert.is_true(h.has_line(d.bufnr, 'Query results (1)'))
  end)

  it('lists result files under the expanded section, sorted ascending', function()
    d = make_drawer()
    d:open()
    dbout.save_dbout(save_dir .. '/30.dbout')
    dbout.save_dbout(save_dir .. '/2.dbout')
    d:set_expanded(ids.DBOUT, true)
    d:render()
    local body = h.buf_lines(d.bufnr)
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
    d = make_drawer(nil, { results = { list_sort = 'desc' } })
    d:open()
    assert.is_true(dbout.sort_dbout('/x/30.dbout', '/x/2.dbout'))
    assert.is_false(dbout.sort_dbout('/x/2.dbout', '/x/30.dbout'))
  end)
end)

describe('dbout: execute on save (sqlite)', function()
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

  it('runs the buffer on :w and renders rows in a .dbout buffer', function()
    local url =
      h.sqlite_db("CREATE TABLE contacts(id INTEGER, name TEXT); INSERT INTO contacts VALUES (1,'ada'),(2,'alan');")
    if not url then
      return pending('sqlite3 not installed')
    end
    d = make_drawer({ qa = url }, { query = { execute_on_save = true } })
    d.connector = require('dadbod-ui.bridge').connect -- real connection
    d:open()
    local entry = h.entry_named(d, 'qa')
    d:query():open({ type = 'query', key_name = entry.key_name }, 'edit')
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
