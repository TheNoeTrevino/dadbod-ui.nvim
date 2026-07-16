-- Real table helpers, per adapter: open EVERY canned helper for the seeded
-- `people` table exactly the way the drawer does ({table}/{schema}
-- substitution through Query:open) and execute it against the live server.
-- This is the regression net for the helper SQL itself -- a typo in an
-- adapter's information_schema query passes every unit test and fails only
-- here. `List` additionally asserts on the rows; the rest assert the
-- statement completed without an error notification.

local h = dofile('integration/helper.lua')
local table_helpers = require('dadbod-ui.table_helpers')

for _, adapter in ipairs(h.adapters) do
  describe('table helpers ' .. adapter.name, function()
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

    -- One `it` per helper, discovered from the adapter's own catalog so a
    -- newly added helper is covered the day it lands.
    local cfg = require('dadbod-ui.config').resolve({})
    local helpers = table_helpers.get(adapter.name, cfg)

    for label, template in pairs(helpers) do
      it(('runs %q against the live server'):format(label), function()
        d = h.make_drawer(adapter)
        d:open()
        local entry = h.entry(d)
        local counter = h.post_counter()
        d:query():open({
          type = 'table',
          key_name = entry.key_name,
          table = 'people',
          schema = adapter.default_schema or '',
          label = label,
          content = template,
        }, 'edit')
        d:query():execute_query()

        assert.is_true(
          h.wait(function()
            return counter.n > 0
          end),
          label .. ' never completed'
        )
        assert.same({}, cap.errors, label .. ' raised an error notification')
        h.assert_no_error_text(adapter, label)
        if label == 'List' then
          assert.is_true(h.wait_for_text('Ann'), 'List should return the seeded rows')
        end
      end)
    end
  end)
end
