-- Real query execution, per adapter: type SQL into a genuine query buffer and
-- execute through the full production path -- query controller → bridge →
-- dadbod → adapter CLI → live server → .dbout result buffer. Asserts on the
-- rows that come back and on the absence of error notifications.

local h = dofile('integration/helper.lua')

for _, adapter in ipairs(h.adapters) do
  describe('execute ' .. adapter.name, function()
    if adapter.url == '' then
      pending(adapter.name .. ' url not configured (run via integration/run.sh)')
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

    it('runs a SELECT and lands the rows in a .dbout buffer', function()
      d = h.make_drawer(adapter)
      h.open_query(d, { "SELECT name FROM people WHERE note = 'has, comma'" })
      d:query():execute_query()

      assert.is_true(h.wait_for_text(adapter.quoted_name), 'expected the matching row in the result buffer')
      assert.same({}, cap.errors)
    end)

    it('round-trips the nasty fixture values (quote, unicode)', function()
      d = h.make_drawer(adapter)
      h.open_query(d, { 'SELECT name FROM people ORDER BY id' })
      d:query():execute_query()

      assert.is_true(h.wait_for_text('Ünïcödé'), 'expected the unicode row')
      assert.is_true(h.dbout_text():find(adapter.quoted_name, 1, true) ~= nil, 'expected the quoted row')
      assert.same({}, cap.errors)
      h.assert_no_error_text(adapter)
    end)

    it('surfaces a broken statement as an error, not a hang', function()
      d = h.make_drawer(adapter)
      local counter = h.post_counter()
      h.open_query(d, { 'SELECT * FROM this_table_does_not_exist_dbui' })
      d:query():execute_query()

      -- dadbod finishes the run either way; the failure lands as an error
      -- notification or as CLI error text in the result buffer.
      assert.is_true(
        h.wait(function()
          return counter.n > 0 or #cap.errors > 0
        end),
        'execution never completed'
      )
    end)
  end)
end
