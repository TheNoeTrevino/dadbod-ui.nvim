-- Real introspection, per adapter: expand a live connection and assert the
-- seeded objects land in the entry -- schemas (postgres lists public AND app),
-- tables (people/orders/numbers everywhere), and routines (postgres `greet`
-- function, mysql/mariadb `greet` procedure). This executes each adapter's
-- ACTUAL catalog SQL (schemes_query / schemes_tables_query / procedures_query)
-- against a real server -- the one thing the stubbed unit specs cannot check.

local h = dofile('integration/helper.lua')
local ids = require('dadbod-ui.drawer.ids')

local function contains(list, want)
  return vim.tbl_contains(list or {}, want)
end

local function routine_names(items)
  return vim.tbl_map(function(r)
    return r.name
  end, items or {})
end

for _, adapter in ipairs(h.adapters) do
  describe('introspection ' .. adapter.name, function()
    if adapter.url == '' then
      pending(adapter.name .. ' url not configured (run via integration/run.sh)')
      return
    end

    local d
    after_each(function()
      h.cleanup(d)
      d = nil
    end)

    it('expands a live connection and finds the seeded objects', function()
      d = h.make_drawer(adapter)
      d:open()
      local entry = h.entry(d)
      d:set_expanded(ids.db(entry.key_name), true)
      d:introspect():expand_db(entry)

      if adapter.schemas then
        assert.is_true(
          h.wait(function()
            return contains(entry.schemas.list, adapter.default_schema)
          end),
          'schema list never populated'
        )
        assert.is_true(contains(entry.schemas.list, 'app'), 'second schema (app) not listed')
        local tables = entry.schemas.items[adapter.default_schema]
        for _, t in ipairs({ 'people', 'orders', 'numbers' }) do
          assert.is_true(contains(tables, t), t .. ' missing from ' .. adapter.default_schema)
        end
        assert.is_true(contains(entry.schemas.items.app, 'orders_archive'), 'app.orders_archive not listed')
      else
        assert.is_true(
          h.wait(function()
            return contains(entry.tables, 'people')
          end),
          'table list never populated'
        )
        for _, t in ipairs({ 'people', 'orders', 'numbers' }) do
          assert.is_true(contains(entry.tables, t), t .. ' missing from tables')
        end
      end
    end)

    it((adapter.routines and 'lists' or 'does not list') .. ' the seeded routine', function()
      d = h.make_drawer(adapter)
      d:open()
      local entry = h.entry(d)
      d:set_expanded(ids.db(entry.key_name), true)
      d:introspect():expand_db(entry)

      if adapter.routines then
        assert.is_true(
          h.wait(function()
            local names = {}
            vim.list_extend(names, routine_names(entry.routines.flat))
            for _, per_schema in pairs(entry.routines.items) do
              vim.list_extend(names, routine_names(per_schema))
            end
            return contains(names, 'greet')
          end),
          'routine greet never listed'
        )
      else
        -- Wait for the table list (introspection settled), then routines must
        -- be empty: this adapter has no routine support, a clean no-op.
        assert.is_true(h.wait(function()
          return contains(entry.tables, 'people')
        end))
        assert.same({}, entry.routines.flat)
        assert.same({}, entry.routines.list)
      end
    end)
  end)
end
