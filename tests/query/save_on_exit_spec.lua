-- Specs for `query.save_on_exit` (issue #74): the quit sweep that settles
-- modified SCRATCH query buffers so Vim doesn't raise its "No write since last
-- change" prompt once per buffer. Saved queries are real files the user named,
-- so the sweep must leave them alone. Nothing is executed here.

local h = require('helper')

local SAVE_ROOT = h.tmp_dir()
local TMP_ROOT = h.tmp_dir()

-- A drawer whose scratch buffers land in TMP_ROOT when `tmp` is true; otherwise
-- `tmp_query_location` stays unset and state falls back to the session temp dir.
local function make_drawer(save_on_exit, tmp)
  return h.make_drawer({
    config = {
      save_location = SAVE_ROOT,
      tmp_query_location = tmp and TMP_ROOT or '',
      query = { save_on_exit = save_on_exit },
    },
  })
end

-- Open a scratch query buffer and leave it modified, as if the user typed in it
-- and never ran/saved it. Returns its bufnr.
local function open_modified_scratch(d)
  local entry = h.entry_named(d, 'qa')
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
    h.clean_ui()
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
    local entry = h.entry_named(d, 'qa')
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

    d = h.make_drawer({
      config = {
        save_location = SAVE_ROOT,
        tmp_query_location = TMP_ROOT,
        query = { save_on_exit = 'auto', execute_on_save = true },
      },
    })
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
