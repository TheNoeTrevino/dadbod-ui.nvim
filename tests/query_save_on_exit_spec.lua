-- Specs for `query.save_on_exit` (issue #74): the quit sweep that settles
-- modified SCRATCH query buffers so Vim doesn't raise its "No write since last
-- change" prompt once per buffer. Saved queries are real files the user named,
-- so the sweep must leave them alone. Nothing is executed here.

local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')

local SAVE_ROOT = '/tmp/dbui_exit_save'
local TMP_ROOT = '/tmp/dbui_exit_tmp'

-- A drawer whose scratch buffers land in TMP_ROOT when `tmp` is true; otherwise
-- `tmp_query_location` stays unset and state falls back to the session temp dir.
local function make_drawer(save_on_exit, tmp)
  vim.fn.delete(SAVE_ROOT, 'rf')
  vim.fn.delete(TMP_ROOT, 'rf')
  local cfg = config.resolve({
    save_location = SAVE_ROOT,
    tmp_query_location = tmp and TMP_ROOT or '',
    drawer = { show_help = false },
    query = { save_on_exit = save_on_exit },
  })
  local instance = state.new(cfg):populate({ env = {}, g_dbs = { qa = 'sqlite:/tmp/qa.db' }, file_entries = {} })
  local d = drawer_mod.new(instance)
  d.connector = function(url)
    return url
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

-- Open a scratch query buffer and leave it modified, as if the user typed in it
-- and never ran/saved it. Returns its bufnr.
local function open_modified_scratch(d)
  local entry = entry_qa(d)
  d:query():open({ type = 'query', key_name = entry.key_name }, 'edit')
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'select 1;' })
  vim.bo[bufnr].modified = true
  return bufnr
end

describe('query: save_on_exit', function()
  local d
  local bufs = {}

  before_each(function()
    require('helper').clean_ui()
  end)

  after_each(function()
    for _, b in ipairs(bufs) do
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
    bufs = {}
    if d then
      d:close()
      d = nil
    end
    vim.fn.delete(SAVE_ROOT, 'rf')
    vim.fn.delete(TMP_ROOT, 'rf')
  end)

  it("'auto' with no tmp_query_location discards the scratch buffer", function()
    d = make_drawer('auto', false)
    d:open()
    local bufnr = open_modified_scratch(d)
    bufs[#bufs + 1] = bufnr

    d:query():sweep_on_exit()

    -- Nothing to prompt about: the session temp dir is wiped on exit anyway.
    assert.is_false(vim.bo[bufnr].modified)
    assert.equals(0, vim.fn.filereadable(vim.api.nvim_buf_get_name(bufnr)))
  end)

  it("'auto' with a tmp_query_location writes the scratch buffer to disk", function()
    d = make_drawer('auto', true)
    d:open()
    local bufnr = open_modified_scratch(d)
    bufs[#bufs + 1] = bufnr
    local name = vim.api.nvim_buf_get_name(bufnr)

    d:query():sweep_on_exit()

    assert.is_false(vim.bo[bufnr].modified)
    assert.equals(1, vim.fn.filereadable(name))
    assert.same({ 'select 1;' }, vim.fn.readfile(name))
  end)

  it("'discard' leaves the file unwritten even with a tmp_query_location", function()
    d = make_drawer('discard', true)
    d:open()
    local bufnr = open_modified_scratch(d)
    bufs[#bufs + 1] = bufnr

    d:query():sweep_on_exit()

    assert.is_false(vim.bo[bufnr].modified)
    assert.equals(0, vim.fn.filereadable(vim.api.nvim_buf_get_name(bufnr)))
  end)

  it("'ask' leaves the buffer modified so Vim still prompts", function()
    d = make_drawer('ask', true)
    d:open()
    local bufnr = open_modified_scratch(d)
    bufs[#bufs + 1] = bufnr

    d:query():sweep_on_exit()

    assert.is_true(vim.bo[bufnr].modified)
  end)

  it('never sweeps a saved query, which is a real file the user named', function()
    d = make_drawer('auto', true)
    d:open()
    local entry = entry_qa(d)
    vim.fn.mkdir(entry.save_path, 'p')
    local saved = entry.save_path .. '/report.sql'
    vim.fn.writefile({ 'select 1;' }, saved)

    d:query():open_buffer(entry, saved, 'edit')
    local bufnr = vim.api.nvim_get_current_buf()
    bufs[#bufs + 1] = bufnr
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'select 2;' })
    vim.bo[bufnr].modified = true

    d:query():sweep_on_exit()

    -- Still modified (Vim will prompt) and the file on disk is untouched.
    assert.is_true(vim.bo[bufnr].modified)
    assert.same({ 'select 1;' }, vim.fn.readfile(saved))
  end)

  it('does not execute the query when writing under execute_on_save', function()
    local bridge = require('dadbod-ui.bridge')

    vim.fn.delete(TMP_ROOT, 'rf')
    local cfg = config.resolve({
      save_location = SAVE_ROOT,
      tmp_query_location = TMP_ROOT,
      drawer = { show_help = false },
      query = { save_on_exit = 'auto', execute_on_save = true },
    })
    local instance = state.new(cfg):populate({ env = {}, g_dbs = { qa = 'sqlite:/tmp/qa.db' }, file_entries = {} })
    d = drawer_mod.new(instance)
    d.connector = function(url)
      return url
    end
    d:open()
    local bufnr = open_modified_scratch(d)
    bufs[#bufs + 1] = bufnr

    -- Stub BOTH engine entry points: a plain `SELECT` auto-paginates and so runs
    -- through `execute_lines`, not the whole-buffer `execute_buffer` fast path.
    local saved_buffer, saved_lines = bridge.execute_buffer, bridge.execute_lines
    local executed = false
    bridge.execute_buffer = function()
      executed = true
    end
    bridge.execute_lines = function()
      executed = true
    end
    d:query():sweep_on_exit()
    bridge.execute_buffer, bridge.execute_lines = saved_buffer, saved_lines

    -- The sweep writes with `noautocmd`, so BufWritePost never fires: quitting
    -- must not run every scratch query on the way out.
    assert.is_false(executed)
    assert.is_false(vim.bo[bufnr].modified)
  end)
end)
