-- Specs for saved queries (M7): saving the current query to the connection's
-- save_path, and the drawer-driven delete (d) and rename (r) of saved queries.
-- No DB binary is needed -- nothing is executed.

local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')

local SAVE_ROOT = '/tmp/dbui_saved'

local function make_drawer(input)
  vim.fn.delete(SAVE_ROOT, 'rf')
  local cfg = config.resolve({ save_location = SAVE_ROOT, show_help = false })
  local instance = state.new(cfg):populate({ env = {}, g_dbs = { qa = 'sqlite:/tmp/qa.db' }, file_entries = {} })
  local d = drawer_mod.new(instance)
  d.connector = function(url)
    return url
  end
  if input then
    d.input = input
  end
  d.confirm = function()
    return true
  end
  return d
end

local function entry_qa(d)
  for _, record in ipairs(d.instance.dbs_list) do
    if record.name == 'qa' then
      return d.instance.dbs[record.key_name]
    end
  end
end

local function has_line(d, pattern)
  for _, line in ipairs(vim.api.nvim_buf_get_lines(d.bufnr, 0, -1, false)) do
    if line:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local function line_of(d, pred)
  for i, node in ipairs(d.content) do
    if pred(node) then
      return i
    end
  end
end

describe('saved queries', function()
  local d
  local extra_bufs = {}

  after_each(function()
    for _, b in ipairs(extra_bufs) do
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
    extra_bufs = {}
    if d then
      d:close()
      d = nil
    end
    vim.fn.delete(SAVE_ROOT, 'rf')
  end)

  it('saves the current query under the connection save_path', function()
    d = make_drawer(function(_, cb)
      cb('myquery.sql')
    end)
    d:open()
    local entry = entry_qa(d)
    d:query():open({ type = 'query', key_name = entry.key_name }, 'edit')
    extra_bufs[#extra_bufs + 1] = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'select 1' })
    d:query():save_query()

    local saved = entry.save_path .. '/myquery.sql'
    assert.equals(1, vim.fn.filereadable(saved))
    entry.expanded = true
    entry.saved_queries.expanded = true
    d:render()
    assert.is_true(has_line(d, 'Saved queries (1)'))
    assert.is_true(has_line(d, 'myquery.sql'))
  end)

  it('deletes a saved query (file and node) on d', function()
    d = make_drawer()
    d:open()
    local entry = entry_qa(d)
    vim.fn.mkdir(entry.save_path, 'p')
    local saved = entry.save_path .. '/keep.sql'
    vim.fn.writefile({ 'select 1' }, saved)
    d:load_saved_queries(entry)
    entry.expanded = true
    entry.saved_queries.expanded = true
    d:render()

    local ln = line_of(d, function(n)
      return n.type == 'saved_query' and n.file_path == saved
    end)
    assert.is_not_nil(ln)
    d:set_cursor(ln)
    d:delete_line()

    assert.equals(0, vim.fn.filereadable(saved))
    assert.equals(0, #entry.saved_queries.list)
  end)

  it('renames a saved query (file and node) on r', function()
    d = make_drawer(function(_, cb)
      cb('renamed.sql')
    end)
    d:open()
    local entry = entry_qa(d)
    vim.fn.mkdir(entry.save_path, 'p')
    local saved = entry.save_path .. '/orig.sql'
    vim.fn.writefile({ 'select 1' }, saved)
    d:load_saved_queries(entry)
    entry.expanded = true
    entry.saved_queries.expanded = true
    d:render()

    local ln = line_of(d, function(n)
      return n.type == 'saved_query' and n.file_path == saved
    end)
    assert.is_not_nil(ln)
    d:set_cursor(ln)
    d:rename_line()

    assert.equals(0, vim.fn.filereadable(saved))
    assert.equals(1, vim.fn.filereadable(entry.save_path .. '/renamed.sql'))
    assert.is_true(has_line(d, 'renamed.sql'))
  end)
end)
