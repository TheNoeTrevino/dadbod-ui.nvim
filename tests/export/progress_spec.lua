-- Specs for the export progress spinner on the result winbar
-- (dadbod-ui.dbout.export_start / export_stop / export_in_progress): a single
-- global, right-aligned "Exporting to <FMT>" segment painted on every visible
-- `.dbout` window (so it survives querying) and gone when the export finishes.

local dbout = require('dadbod-ui.dbout')
local spinner = require('dadbod-ui.spinner')

describe('dbout export winbar spinner (single global export)', function()
  local win, buf

  before_each(function()
    buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = 'dbout' -- render targets `.dbout` windows
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
  end)

  after_each(function()
    pcall(spinner.stop, 'dbui_export')
  end)

  local function winbar_of(w)
    return vim.api.nvim_get_option_value('winbar', { win = w })
  end

  it('shows the segment + reports in_progress, and clears both on stop', function()
    assert.is_false(dbout.export_in_progress())
    local token = dbout.export_start(buf, 'json')
    assert.is_true(dbout.export_in_progress())
    local wb = winbar_of(win)
    assert.is_truthy(wb:find('Exporting to JSON', 1, true))
    assert.is_truthy(wb:find('%=', 1, true)) -- right-aligned
    dbout.export_stop(buf, token)
    assert.is_false(dbout.export_in_progress())
    assert.are.equal('', winbar_of(win))
  end)

  it('persists onto a new .dbout window opened mid-export (survives re-querying)', function()
    local token = dbout.export_start(buf, 'csv')
    -- Simulate running another query: a fresh dbout result in a new window.
    vim.cmd('split')
    local win2 = vim.api.nvim_get_current_win()
    local buf2 = vim.api.nvim_create_buf(false, true)
    vim.bo[buf2].filetype = 'dbout'
    vim.api.nvim_win_set_buf(win2, buf2)
    -- The global spinner repaints every dbout window on tick; drive one tick.
    spinner._timers['dbui_export'].tick()
    assert.is_truthy(winbar_of(win2):find('Exporting to CSV', 1, true))
    dbout.export_stop(buf, token)
    assert.are.equal('', winbar_of(win2)) -- cleared everywhere on stop
    pcall(vim.api.nvim_win_close, win2, true)
  end)

  it('ignores a stale stop token', function()
    local token = dbout.export_start(buf, 'csv')
    dbout.export_stop(buf, token + 999) -- not the active token
    assert.is_true(dbout.export_in_progress()) -- still running
    dbout.export_stop(buf, token)
    assert.is_false(dbout.export_in_progress())
  end)
end)
