-- Real EXPLAIN, per adapter that declares an explain template: wrap a live
-- query and assert a genuine plan comes back (each dialect's own marker --
-- postgres 'Seq Scan', sqlite 'SCAN', mysql/mariadb echo the table name in the
-- tabular plan). Proves the adapter's explain template is valid SQL on a real
-- server, not just string interpolation.

local h = dofile('integration/helper.lua')
local explain = require('dadbod-ui.explain')

for _, adapter in ipairs(h.adapters) do
  describe('explain ' .. adapter.name, function()
    if adapter.url == '' then
      pending(adapter.name .. ' url not configured (run via integration/run.sh)')
      return
    end
    if not explain.supports(adapter.name) then
      pending(adapter.name .. ' declares no explain template')
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

    it('returns a real plan for a plain SELECT', function()
      d = h.make_drawer(adapter)
      h.open_query(d, { 'SELECT * FROM people' })
      d:query():explain_query()

      assert.is_true(
        h.wait_for_text(adapter.plan_marker),
        ('expected %q in the plan output'):format(adapter.plan_marker)
      )
      assert.same({}, cap.errors)
    end)
  end)
end
