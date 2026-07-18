-- MongoDB e2e: not SQL, so it gets its own spec instead of an entry in the
-- shared SQL adapter table. dadbod runs mongosh scripts; dadbod-ui's mongodb
-- adapter is deliberately minimal (collections listed as tables through
-- dadbod's `tables` call -- prefixed `db.` -- plus the `{table}.find()`
-- helper). This proves that minimal surface against a live server, and that
-- the classifier-era rule holds: nothing here ever pretends mongo is SQL.
--
-- Runs only under DBUI_IT_EXTRA=1 with mongosh on the host (run.sh exports
-- DBUI_IT_MONGO_URL then); otherwise pending.

local h = dofile('integration/helper.lua')
local ids = require('dadbod-ui.drawer.ids')

local url = vim.env.DBUI_IT_MONGO_URL or ''
local adapter = { name = 'mongodb', url = url }

describe('mongodb', function()
  if url == '' then
    pending('mongodb url not configured (DBUI_IT_EXTRA=1 + mongosh, via integration/run.sh)')
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

  it('lists the seeded collections as tables', function()
    d = h.make_drawer(adapter)
    d:open()
    local entry = h.entry(d)
    d:set_expanded(ids.db(entry.key_name), true)
    d:introspect():expand_db(entry)

    assert.is_true(
      h.wait(function()
        return vim.tbl_contains(entry.tables, 'db.people')
      end),
      'db.people never listed'
    )
    assert.is_true(vim.tbl_contains(entry.tables, 'db.orders'))
    assert.is_true(vim.tbl_contains(entry.tables, 'db.numbers'))
  end)

  it('runs the List helper (find()) against a live collection', function()
    d = h.make_drawer(adapter)
    d:open()
    local entry = h.entry(d)
    d:query():open({
      type = 'table',
      key_name = entry.key_name,
      table = 'db.people',
      schema = '',
      label = 'List',
      content = '{table}.find()',
    }, 'edit')
    d:query():execute_query()

    assert.is_true(h.wait_for_text('Ann'), 'find() never returned the seeded documents')
    assert.same({}, cap.errors)
  end)
end)
