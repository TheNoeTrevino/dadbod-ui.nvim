-- Real EXPLAIN plan trees, end to end: wrap the buffer SQL in the adapter's
-- JSON EXPLAIN form, run it through the REAL client against the live server,
-- decode, and render the tree. This is the proof the whole pipeline holds
-- outside the stubs: the json_args really do produce bare parseable JSON from
-- each client, the parsers really match each server's shape, and ANALYZE
-- really rolls DML back.

local h = dofile('integration/helper.lua')
local explain = require('dadbod-ui.explain')
local tree = require('dadbod-ui.explain.tree')

-- Per-adapter expectations: text the rendered tree must contain for
-- `SELECT * FROM people` (each dialect's scan spelling), and whether the
-- dialect has an executing JSON form (json_analyze).
local EXPECT = {
  postgres = { scan = 'Seq Scan on people', analyze = true },
  mysql = { scan = 'Full Table Scan on people', analyze = false },
  mariadb = { scan = 'Full Table Scan on people', analyze = true },
}

--- The concatenated text of the open tree buffer ('' when closed).
local function tree_text()
  local t = tree.get()
  if t == nil then
    return ''
  end
  return table.concat(vim.api.nvim_buf_get_lines(t.bufnr, 0, -1, false), '\n')
end

--- Wait until the tree is open and its text contains `text`.
local function wait_for_tree(text)
  return h.wait(function()
    return tree_text():find(text, 1, true) ~= nil
  end)
end

for _, adapter in ipairs(h.adapters) do
  local expect = EXPECT[adapter.name]
  describe('explain tree ' .. adapter.name, function()
    if adapter.url == '' then
      pending(adapter.name .. ' url not configured (run via integration/run.sh)')
      return
    end
    if expect == nil then
      if explain.supports_json(adapter.name) then
        error(adapter.name .. ' declares JSON explain support but this spec has no expectations for it')
      end
      pending(adapter.name .. ' has no structured plan format')
      return
    end

    local d, cap
    before_each(function()
      cap = h.capture_notifications()
    end)
    after_each(function()
      tree.close()
      cap.restore()
      h.cleanup(d)
      d = nil
    end)

    it('renders a real plan tree for a SELECT', function()
      d = h.make_drawer(adapter)
      h.open_query(d, { 'SELECT * FROM people' })
      d:query():explain_tree(false)

      assert.is_true(wait_for_tree(expect.scan), ('expected %q in the tree:\n%s'):format(expect.scan, tree_text()))
      local t = assert(tree.get())
      assert.equals('dbui-explain', vim.bo[t.bufnr].filetype)
      -- The metric cells rendered: a cost (plain plans) and a rows estimate.
      assert.is_truthy(tree_text():match('rows ~'))
      assert.is_truthy(tree_text():match('cost '))
      assert.same({}, cap.errors)
    end)

    it('surfaces a server error for bad SQL and opens nothing', function()
      d = h.make_drawer(adapter)
      h.open_query(d, { 'SELECT * FROM no_such_table_dbui' })
      d:query():explain_tree(false)
      assert.is_true(
        h.wait(function()
          return #cap.errors > 0
        end),
        'expected an error notification'
      )
      assert.is_nil(tree.get())
    end)

    if expect.analyze then
      it('renders an analyzed tree with real timings', function()
        d = h.make_drawer(adapter)
        h.open_query(d, { 'SELECT * FROM people' })
        d:query():explain_tree(false, { analyze = true })
        assert.is_true(wait_for_tree('analyzed'), 'expected an analyzed plan header:\n' .. tree_text())
        assert.is_truthy(tree_text():match('%dms') or tree_text():match('%d%%'))
        assert.same({}, cap.errors)
      end)
    end

    if adapter.name == 'postgres' then
      it('rolls back DML under JSON analyze (never commits)', function()
        d = h.make_drawer(adapter)
        -- orders has no inbound foreign keys, so the DELETE itself is valid --
        -- what must protect the rows is the BEGIN/ROLLBACK wrapper, not a
        -- constraint error.
        h.open_query(d, { 'DELETE FROM orders' })
        d:query():explain_tree(false, { analyze = true })
        assert.is_true(wait_for_tree('analyzed'), 'expected the analyzed DELETE plan:\n' .. tree_text())

        tree.close()
        h.open_query(d, { 'SELECT COUNT(*) AS n FROM orders' })
        d:query():execute_query(false)
        assert.is_true(h.wait_for_text('n'), 'count query produced no output')
        assert.is_falsy(h.dbout_text():find('\n0\n', 1, true), 'orders were deleted -- ANALYZE did not roll back')
        h.assert_no_error_text(adapter, 'post-analyze count')
      end)
    end
  end)
end
