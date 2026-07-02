-- Specs for the pagination glue in dadbod-ui.dbout: the winbar segment builders
-- and their composition into the result winbar. The SQL rewrite itself is covered
-- by paginator_spec; the page-step guards exercise _step_page indirectly.

local dbout = require('dadbod-ui.dbout')

local function state(over)
  return vim.tbl_extend('force', {
    original_sql = 'SELECT * FROM t',
    page = 1,
    page_size = 200,
    scheme = 'postgres',
    url = 'x',
  }, over or {})
end

describe('dbout: _page_segment', function()
  it('reports the page, row range and page size', function()
    assert.equals('Page 2 · rows 201-400 · 200/page', dbout._page_segment(state({ page = 2 }), 200))
  end)

  it('uses the actual row count for a partial last page', function()
    -- page 3 of 200 starts at 401; only 37 rows came back -> 401-437
    assert.equals('Page 3 · rows 401-437 · 200/page', dbout._page_segment(state({ page = 3 }), 37))
  end)

  it('falls back to the full page span when the row count is unknown', function()
    assert.equals('Page 2 · rows 201-400 · 200/page', dbout._page_segment(state({ page = 2 }), nil))
  end)

  it('returns nil for an unpaginated result', function()
    assert.is_nil(dbout._page_segment(nil, nil))
  end)
end)

describe('dbout: _nav_segment', function()
  it('renders left/right arrows around the configured page-step keys', function()
    assert.equals('← [   ] →', dbout._nav_segment(state(), '[', ']'))
  end)

  it('reflects rebound keys', function()
    assert.equals('← <C-p>   <C-n> →', dbout._nav_segment(state(), '<C-p>', '<C-n>'))
  end)

  it('returns nil for an unpaginated result', function()
    assert.is_nil(dbout._nav_segment(nil, '[', ']'))
  end)
end)

describe('dbout: _nav_keys', function()
  it('reads the configured [ / ] results mappings', function()
    local keys = dbout._nav_keys(require('dadbod-ui.config').resolve())
    assert.same({ prev = '[', next = ']' }, keys)
  end)

  it('reflects a rebound page-step key', function()
    local cfg = require('dadbod-ui.config').resolve({ mappings = { results = { next_page = { key = '<Tab>' } } } })
    assert.equals('<Tab>', dbout._nav_keys(cfg).next)
  end)
end)

describe('dbout: _winbar_text', function()
  -- The bar is statusline-syntax: each block is `%#<group># <text> `, blocks are
  -- left-aligned and separated by a `%#DadbodUIWinbarFill# ` gap, and the fill
  -- group paints the bar's tail.
  it('builds distinctly-coloured page, summary and nav blocks left-to-right', function()
    local text =
      dbout._winbar_text(state({ page = 2 }), '✓ finished in 0.004s · 200 rows', 200, { prev = '[', next = ']' })
    assert.equals(
      '%#DadbodUIWinbarPage# Page 2 · rows 201-400 · 200/page '
        .. '%#DadbodUIWinbarFill# %#DadbodUIWinbar# ✓ finished in 0.004s · 200 rows '
        .. '%#DadbodUIWinbarFill# %#DadbodUIWinbarNav# ← [   ] → '
        .. '%#DadbodUIWinbarFill#',
      text
    )
  end)

  it('renders only the summary block when the result is not paged', function()
    assert.equals(
      '%#DadbodUIWinbar# ✓ finished in 0.004s %#DadbodUIWinbarFill#',
      dbout._winbar_text(nil, '✓ finished in 0.004s', nil)
    )
  end)

  it('renders only the pagination + nav blocks when query_time is off (no summary)', function()
    assert.equals(
      '%#DadbodUIWinbarPage# Page 1 · rows 1-200 · 200/page '
        .. '%#DadbodUIWinbarFill# %#DadbodUIWinbarNav# ← [   ] → '
        .. '%#DadbodUIWinbarFill#',
      dbout._winbar_text(state(), nil, 200, { prev = '[', next = ']' })
    )
  end)

  it('returns an empty string when there is nothing to show', function()
    assert.equals('', dbout._winbar_text(nil, nil, nil))
  end)

  it('doubles a literal % in engine summary text so it is not a control code', function()
    assert.equals('%#DadbodUIWinbar# 50%% done %#DadbodUIWinbarFill#', dbout._winbar_text(nil, '50% done', nil))
  end)
end)

describe('dbout: _step_page last-page guard', function()
  local bridge = require('dadbod-ui.bridge')
  local notify = require('dadbod-ui.notifications')
  local runs, infos, orig_exec, orig_info

  before_each(function()
    runs, infos = {}, {}
    orig_exec, orig_info = bridge.execute_lines, notify.info
    bridge.execute_lines = function(lines)
      table.insert(runs, table.concat(lines, '\n'))
    end
    notify.info = function(msg)
      table.insert(infos, msg)
    end
  end)

  after_each(function()
    bridge.execute_lines, notify.info = orig_exec, orig_info
    vim.b.dbui_page = nil
  end)

  it('refuses to advance past a page flagged as the last one', function()
    vim.b.dbui_page = state({ page = 1, last = true })
    dbout.next_page()
    assert.same({}, runs)
    assert.equals('Already on the last page of results.', infos[1])
  end)

  it('still advances when the current page is not the last', function()
    vim.b.dbui_page = state({ page = 1, last = false })
    dbout.next_page()
    assert.equals('SELECT * FROM t LIMIT 200 OFFSET 200', runs[1])
  end)

  it('allows stepping back from the last page', function()
    vim.b.dbui_page = state({ page = 2, last = true })
    dbout.prev_page()
    assert.equals('SELECT * FROM t LIMIT 200 OFFSET 0', runs[1])
    assert.same({}, infos)
  end)
end)

describe('dbout: _step_page clears the stale last flag', function()
  local bridge = require('dadbod-ui.bridge')
  local pagination = require('dadbod-ui.dbout.pagination')
  local captured, orig_exec

  before_each(function()
    captured = nil
    orig_exec = bridge.execute_lines
    bridge.execute_lines = function() end
    -- Intercept the page state _step_page arms for the next execution.
    pagination._set_pending_fn(function(s)
      captured = s
    end)
  end)

  after_each(function()
    bridge.execute_lines = orig_exec
    pagination._set_pending_fn(dbout.set_pending) -- restore init's channel
    vim.b.dbui_page = nil
  end)

  it('drops last when stepping forward off a non-last page', function()
    vim.b.dbui_page = state({ page = 1, last = false })
    dbout.next_page()
    assert.equals(2, captured.page)
    -- last belongs to the page we left; it must be recomputed for the new page,
    -- so a failed row count can't carry a stale true forward and jam `]`.
    assert.is_nil(captured.last)
  end)

  it('drops last when stepping back off the last page', function()
    vim.b.dbui_page = state({ page = 3, last = true })
    dbout.prev_page()
    assert.equals(2, captured.page)
    assert.is_nil(captured.last)
  end)
end)
