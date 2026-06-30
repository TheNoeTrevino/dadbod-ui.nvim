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
  it('renders the prev/next hints when paged', function()
    assert.equals('[ prev  ] next', dbout._nav_segment(state()))
  end)

  it('returns nil for an unpaginated result', function()
    assert.is_nil(dbout._nav_segment(nil))
  end)
end)

describe('dbout: _winbar_text', function()
  -- The bar is statusline-syntax: each block is `%#<group># <text> ` and the
  -- blocks are spread with `%#DadbodUIWinbarFill#%=` (justify-content: space-between).
  it('styles the pagination, summary and nav blocks and spreads them with %=', function()
    local text = dbout._winbar_text(state({ page = 2 }), '✓ finished in 0.004s · 200 rows', 200)
    assert.equals(
      '%#DadbodUIWinbarPage# Page 2 · rows 201-400 · 200/page '
        .. '%#DadbodUIWinbarFill#%=%#DadbodUIWinbar# ✓ finished in 0.004s · 200 rows '
        .. '%#DadbodUIWinbarFill#%=%#DadbodUIWinbar# [ prev  ] next ',
      text
    )
  end)

  it('renders only the summary block when the result is not paged', function()
    assert.equals('%#DadbodUIWinbar# ✓ finished in 0.004s ', dbout._winbar_text(nil, '✓ finished in 0.004s', nil))
  end)

  it('renders only the pagination + nav blocks when query_time is off (no summary)', function()
    assert.equals(
      '%#DadbodUIWinbarPage# Page 1 · rows 1-200 · 200/page %#DadbodUIWinbarFill#%=%#DadbodUIWinbar# [ prev  ] next ',
      dbout._winbar_text(state(), nil, 200)
    )
  end)

  it('returns an empty string when there is nothing to show', function()
    assert.equals('', dbout._winbar_text(nil, nil, nil))
  end)

  it('doubles a literal % in engine summary text so it is not a control code', function()
    assert.equals('%#DadbodUIWinbar# 50%% done ', dbout._winbar_text(nil, '50% done', nil))
  end)
end)
