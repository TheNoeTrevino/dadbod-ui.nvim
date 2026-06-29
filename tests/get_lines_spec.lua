-- Spec for Query:get_lines (the visual branch). The visual selection is read via
-- vim.fn.getregion over the '<'/'>' marks instead of a normal-mode `gvy` yank, so
-- the user's unnamed (`"`) register must be left completely untouched -- this is
-- the regression the rewrite guards against.

local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')

local function make_query()
  local cfg = config.resolve({ save_location = '/tmp/dbui_getlines', show_help = false })
  local instance = state.new(cfg):populate({ env = {}, g_dbs = { qa = 'sqlite:/tmp/qa.db' }, file_entries = {} })
  return drawer_mod.new(instance):query()
end

describe('Query:get_lines visual branch', function()
  local buf

  before_each(function()
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'first line', 'second line', 'third line' })
  end)

  after_each(function()
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it('returns the linewise selection without clobbering the " register', function()
    vim.fn.setreg('"', 'SENTINEL-REGISTER-VALUE')

    -- Select the first two lines linewise, then leave visual mode so '<'/'>' set.
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd('normal! Vj')
    vim.cmd('normal! \27')

    local lines = make_query():get_lines(true)

    assert.same({ 'first line', 'second line' }, lines)
    assert.equals('SENTINEL-REGISTER-VALUE', vim.fn.getreg('"'))
  end)

  it('returns a charwise (inclusive) selection without clobbering the " register', function()
    vim.fn.setreg('"', 'KEEP-ME')

    -- Charwise-select `second` on the second line (inclusive, like the old gvy).
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd('normal! v5l')
    vim.cmd('normal! \27')

    local lines = make_query():get_lines(true)

    assert.same({ 'second' }, lines)
    assert.equals('KEEP-ME', vim.fn.getreg('"'))
  end)
end)
