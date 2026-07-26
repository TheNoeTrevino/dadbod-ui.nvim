-- End-to-end bind-parameter specs (M9): real SQL run through dadbod against a
-- sqlite fixture, asserting the substituted query returns the right rows in the
-- .dbout buffer. Guarded on the sqlite3 binary (pending() when absent). Proves
-- numeric vs string quoting and a custom pattern over the actual engine, not a
-- stub -- the regression complement to the stubbed flow specs.

local bridge = require('dadbod-ui.bridge')
local h = require('helper')

-- Collect the text of every open .dbout buffer.
local function dbout_text()
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match('%.dbout$') then
      vim.list_extend(out, vim.api.nvim_buf_get_lines(b, 0, -1, false))
    end
  end
  return table.concat(out, '\n')
end

local function wait_for(text)
  return vim.wait(5000, function()
    return dbout_text():find(text, 1, true) ~= nil
  end, 50)
end

describe('bind params: end-to-end (sqlite)', function()
  local d, query_buf, db_url

  before_each(function()
    h.clean_ui()
    db_url = h.sqlite_db(
      "CREATE TABLE users(id INTEGER, name TEXT); INSERT INTO users VALUES (1,'ada'),(2,'alan'),(3,'O''Brien');"
    )
  end)

  after_each(function()
    if query_buf then
      pcall(vim.api.nvim_buf_delete, query_buf, { force = true })
      query_buf = nil
    end
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(b):match('%.dbout$') then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    if d then
      d:close()
      d = nil
    end
  end)

  local function open_query(d_, lines)
    d_:open()
    local entry = h.entry_named(d_, 'qa')
    d_:query():open({ type = 'query', key_name = entry.key_name }, 'edit')
    query_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  end

  it('substitutes a numeric param bare and returns the matching row', function()
    if not db_url then
      return pending('sqlite3 not installed')
    end
    d = h.make_drawer({ g_dbs = { qa = db_url }, connector = bridge.connect })
    open_query(d, { 'SELECT name FROM users WHERE id = :id;' })
    d:query().input = function(_, on_confirm)
      on_confirm('2')
    end
    d:query():execute_query()

    assert.is_true(wait_for('alan'), 'expected the row for id=2')
    assert.is_false(dbout_text():find('ada', 1, true) ~= nil) -- only the matched row
    assert.same({ [':id'] = '2' }, vim.b[query_buf].dbui_bind_params)
  end)

  it('quotes a string param and returns the matching row', function()
    if not db_url then
      return pending('sqlite3 not installed')
    end
    d = h.make_drawer({ g_dbs = { qa = db_url }, connector = bridge.connect })
    open_query(d, { 'SELECT id FROM users WHERE name = :name;' })
    d:query().input = function(_, on_confirm)
      on_confirm('alan')
    end
    d:query():execute_query()

    assert.is_true(wait_for('2'), 'expected id=2 for name=alan')
  end)

  it('escapes an embedded quote in a string param', function()
    if not db_url then
      return pending('sqlite3 not installed')
    end
    d = h.make_drawer({ g_dbs = { qa = db_url }, connector = bridge.connect })
    open_query(d, { 'SELECT id FROM users WHERE name = :name;' })
    d:query().input = function(_, on_confirm)
      on_confirm("O'Brien")
    end
    d:query():execute_query()

    assert.is_true(wait_for('3'), "expected id=3 for name=O'Brien (quote escaped)")
  end)

  it('honors a custom $N bind_param_pattern', function()
    if not db_url then
      return pending('sqlite3 not installed')
    end
    d = h.make_drawer({
      g_dbs = { qa = db_url },
      connector = bridge.connect,
      config = { query = { bind_param_pattern = '\\$\\d\\+' } },
    })
    open_query(d, { 'SELECT name FROM users WHERE id = $1;' })
    d:query().input = function(_, on_confirm)
      on_confirm('1')
    end
    d:query():execute_query()

    assert.is_true(wait_for('ada'), 'expected the row for $1=1')
  end)
end)
