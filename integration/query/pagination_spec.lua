-- Real pagination, per adapter that supports it: a 250-row SELECT auto-
-- paginates to the default 200-row page 1, then `]` (dbout.next_page) re-
-- executes at the real server for page 2 -- rows 201..250 -- and flags it as
-- the last page. Exercises the paginator's LIMIT-clause rewrite against each
-- dialect for real, plus the page-state handoff through dadbod's events.

local h = dofile('integration/helper.lua')
local dbout = require('dadbod-ui.dbout')

-- Focus the (single) .dbout window so next_page reads its b:dbui_page.
local function focus_dbout()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_get_name(buf):match('%.dbout$') then
      vim.api.nvim_set_current_win(win)
      return buf
    end
  end
end

for _, adapter in ipairs(h.adapters) do
  describe('pagination ' .. adapter.name, function()
    if adapter.url == '' then
      pending(adapter.name .. ' url not configured (run via integration/run.sh)')
      return
    end
    if not require('dadbod-ui.paginator').supports(adapter.name) then
      pending(adapter.name .. ' does not support pagination')
      return
    end

    local d, cap
    before_each(function()
      cap = h.capture_notifications()
    end)
    after_each(function()
      cap.restore()
      h.cleanup(d)
      d = nil
    end)

    it('serves page 1 (200 rows) and steps to the last page (201..250)', function()
      d = h.make_drawer(adapter)
      h.open_query(d, { 'SELECT n FROM numbers ORDER BY n' })
      d:query():execute_query()

      -- Page 1 ends at row 200; row 250 must NOT be there yet.
      assert.is_true(h.wait_for_text('200'), 'page 1 never loaded')
      assert.is_true(
        h.wait(function()
          local buf = focus_dbout()
          return buf ~= nil and type(vim.b[buf].dbui_page) == 'table'
        end),
        'page state never tagged onto the result buffer'
      )
      assert.is_nil(h.dbout_text():find('250', 1, true))
      local page1 = vim.b[vim.api.nvim_get_current_buf()].dbui_page
      assert.equals(1, page1.page)
      assert.equals(200, page1.page_size)

      -- Step to page 2: rows 201..250 replace the first page.
      dbout.next_page()
      assert.is_true(h.wait_for_text('250'), 'page 2 never loaded')
      assert.is_true(
        h.wait(function()
          local buf = focus_dbout()
          return buf ~= nil and type(vim.b[buf].dbui_page) == 'table' and vim.b[buf].dbui_page.page == 2
        end),
        'page 2 state never tagged'
      )
      -- A 50-row page is a short page: stepping further must refuse.
      assert.is_true(
        h.wait(function()
          local buf = focus_dbout()
          return buf ~= nil and vim.b[buf].dbui_page.last == true
        end),
        'short page never flagged as last'
      )
      focus_dbout()
      dbout.next_page()
      assert.is_true(h.wait(function()
        return vim.tbl_contains(cap.infos, 'Already on the last page of results.')
      end, 5000))
      assert.same({}, cap.errors)
    end)

    it('does not paginate a query that already carries LIMIT', function()
      d = h.make_drawer(adapter)
      h.open_query(d, { 'SELECT n FROM numbers ORDER BY n LIMIT 5' })
      d:query():execute_query()

      assert.is_true(h.wait_for_text('5'), 'limited query never returned')
      local buf = focus_dbout()
      assert.is_not_nil(buf)
      assert.is_nil(vim.b[buf].dbui_page, 'an already-limited query must not be page-tagged')
      assert.same({}, cap.errors)
    end)
  end)
end
