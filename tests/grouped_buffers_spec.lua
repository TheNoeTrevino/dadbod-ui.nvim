-- Specs for group-qualified buffer/save naming: a connection name reused across
-- groups must namespace its tmp query files AND its save folder by group, and
-- resolve a saved/tmp buffer back to the RIGHT connection (never the other
-- group's, which shares the bare name). See utils.qualified_name.

local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')

local SAVE_ROOT = '/tmp/dbui_grouped'
local TMP_ROOT = '/tmp/dbui_grouped_tmp'

-- Two connections both named 'prod' (groups a/b), plus an ungrouped 'stage'.
local function make_drawer()
  vim.fn.delete(SAVE_ROOT, 'rf')
  vim.fn.delete(TMP_ROOT, 'rf')
  local cfg = config.resolve({
    save_location = SAVE_ROOT,
    tmp_query_location = TMP_ROOT,
    show_help = false,
  })
  local instance = state.new(cfg):populate({
    env = {},
    g_dbs = {},
    file_entries = {
      { name = 'prod', url = 'sqlite:/tmp/a.db', group = 'a' },
      { name = 'prod', url = 'sqlite:/tmp/b.db', group = 'b' },
      { name = 'stage', url = 'sqlite:/tmp/stage.db' },
    },
  })
  local d = drawer_mod.new(instance)
  d.connector = function(url)
    return url
  end
  return d
end

local function entry(d, key_name)
  return d.instance.dbs[key_name]
end

describe('grouped buffer/save naming', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
    vim.fn.delete(SAVE_ROOT, 'rf')
    vim.fn.delete(TMP_ROOT, 'rf')
    vim.cmd('silent! %bwipeout!')
  end)

  it('namespaces the save folder by group', function()
    d = make_drawer()
    assert.equals(SAVE_ROOT .. '/a_prod', entry(d, 'a_prod_file').save_path)
    assert.equals(SAVE_ROOT .. '/b_prod', entry(d, 'b_prod_file').save_path)
    assert.equals(SAVE_ROOT .. '/stage', entry(d, 'stage_file').save_path)
  end)

  it('prefixes tmp query files with the group-qualified name', function()
    d = make_drawer()
    local b = entry(d, 'b_prod_file')
    d:query():open({ type = 'query', key_name = b.key_name }, 'edit')
    local tail = vim.fs.basename(vim.api.nvim_buf_get_name(0))
    assert.is_truthy(tail:match('^b_prod%-'), 'expected b_prod- prefix, got ' .. tail)
  end)

  it('resolves a saved-folder query to the owning group, not the shared name', function()
    d = make_drawer()
    local b = entry(d, 'b_prod_file')
    vim.fn.mkdir(b.save_path, 'p')
    local saved = b.save_path .. '/report.sql'
    vim.fn.writefile({ 'select 1' }, saved)
    vim.cmd('edit ' .. vim.fn.fnameescape(saved))

    -- The qualified folder name identifies the connection unambiguously.
    assert.equals('b_prod', d:query():get_saved_query_db_name())

    local picked
    d:pick_db('b_prod', function(e)
      picked = e
    end)
    assert.equals(b.key_name, picked.key_name)
  end)

  it('resolves a tmp query buffer back to its exact group', function()
    d = make_drawer()
    local a = entry(d, 'a_prod_file')
    -- Open a real tmp buffer on group a, then ask which db it belongs to.
    d:query():open({ type = 'query', key_name = a.key_name }, 'edit')
    assert.equals('a_prod', d:query():get_saved_query_db_name())

    local picked
    d:pick_db(d:query():get_saved_query_db_name(), function(e)
      picked = e
    end)
    assert.equals(a.key_name, picked.key_name)
  end)

  it('still resolves an ungrouped connection by its bare name', function()
    d = make_drawer()
    local s = entry(d, 'stage_file')
    d:query():open({ type = 'query', key_name = s.key_name }, 'edit')
    local tail = vim.fs.basename(vim.api.nvim_buf_get_name(0))
    assert.is_truthy(tail:match('^stage%-'), 'expected stage- prefix, got ' .. tail)
    assert.equals('stage', d:query():get_saved_query_db_name())
  end)
end)
