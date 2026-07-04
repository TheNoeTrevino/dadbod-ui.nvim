-- Specs for the connection picker (`dadbod-ui.picker`): item building, the
-- vim.ui.select fallback, router dispatch and the api facade.

local api = require('dadbod-ui.api')
local state = require('dadbod-ui.state')
local picker = require('dadbod-ui.picker')
local picker_utils = require('dadbod-ui.picker.utils')
local notifications = require('dadbod-ui.notifications')

-- Seed the session singleton with injected connections (see api_spec.lua).
local function seed(g_dbs, overrides)
  vim.g.dbs = g_dbs
  local opts = vim.tbl_extend('force', { save_location = '/tmp/dbui_picker', show_help = false }, overrides or {})
  state.setup(opts)
  state.get() -- force discovery now
end

-- Swap vim.ui.select for a stub, returning it for assertions; the stub records
-- every (items, opts) it is shown (last one on `items`/`opts`, all on `calls`)
-- and picks via `choose(items)` (nil = cancel).
local function stub_select(choose)
  local original = vim.ui.select
  local seen = { called = false, calls = {} }
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.ui.select = function(items, opts, on_choice)
    seen.called = true
    seen.items = items
    seen.opts = opts
    table.insert(seen.calls, { items = items, opts = opts })
    on_choice(choose and choose(items) or nil)
  end
  return seen, function()
    vim.ui.select = original
  end
end

describe('picker: items', function()
  after_each(function()
    vim.g.dbs = nil
    state.reset()
  end)

  it('maps every discovered connection, labeled group/name', function()
    seed({
      { name = 'dev', url = 'sqlite:/tmp/dev.db' },
      { name = 'prod', url = 'sqlite:/tmp/prod.db', group = 'work' },
    })
    local items = picker_utils.build_items()
    assert.equals(2, #items)
    assert.equals('dev', items[1].label)
    assert.equals('work/prod', items[2].label)
    assert.equals('sqlite:/tmp/dev.db', items[1].url)
    assert.is_false(items[1].is_connected)
    -- text is the fuzzy haystack: label + url, both matchable
    assert.truthy(items[2].text:find('work/prod', 1, true))
    assert.truthy(items[2].text:find('sqlite:/tmp/prod.db', 1, true))
    -- key_name resolves through the api addressing
    assert.truthy(api.info(items[2].key_name))
  end)
end)

describe('picker: fallback + routing', function()
  after_each(function()
    vim.g.dbs = nil
    state.reset()
  end)

  it('routes auto to vim.ui.select when no picker plugin is installed', function()
    seed({ { name = 'dev', url = 'sqlite:/tmp/dev.db' } })
    local seen, restore = stub_select(nil)
    picker.show()
    restore()
    assert.is_true(seen.called)
    assert.equals('Connections', seen.opts.prompt)
    assert.equals('dev', seen.items[1].label)
    assert.equals(seen.items[1].text, seen.opts.format_item(seen.items[1]))
  end)

  it('connects the chosen item', function()
    seed({ { name = 'dev', url = 'sqlite:/tmp/dev.db' } })
    local connected = nil
    local original_connect = api.connect
    ---@diagnostic disable-next-line: duplicate-set-field
    api.connect = function(name, cb)
      connected = name
      cb(true)
    end
    local _, restore = stub_select(function(items)
      return items[1]
    end)
    picker.show()
    restore()
    api.connect = original_connect
    assert.truthy(connected)
    assert.truthy(api.info(connected))
  end)

  it('is a notified no-op when there are no connections', function()
    seed({}, { save_location = '/tmp/dbui_picker_empty' })
    local seen, restore = stub_select(nil)
    picker.show()
    restore()
    assert.is_false(seen.called)
    assert.equals('No connections found', notifications.get_last_msg())
  end)

  it('warns when a forced backend is not installed', function()
    seed({ { name = 'dev', url = 'sqlite:/tmp/dev.db' } }, { picker = 'snacks' })
    local seen, restore = stub_select(nil)
    picker.show()
    restore()
    assert.is_false(seen.called)
    assert.equals("picker 'snacks' is not available", notifications.get_last_msg())
  end)

  it('honors picker = "fallback"', function()
    seed({ { name = 'dev', url = 'sqlite:/tmp/dev.db' } }, { picker = 'fallback' })
    local seen, restore = stub_select(nil)
    picker.show()
    restore()
    assert.is_true(seen.called)
  end)
end)

describe('picker: execute_pick', function()
  after_each(function()
    vim.g.dbs = nil
    state.reset()
  end)

  it('runs the sql against the picked connection', function()
    seed({ { name = 'dev', url = 'sqlite:/tmp/dev.db' } })
    local executed = nil
    local original_execute = api.execute
    ---@diagnostic disable-next-line: duplicate-set-field
    api.execute = function(name, sql)
      executed = { name = name, sql = sql }
      return true
    end
    local _, restore = stub_select(function(items)
      return items[1]
    end)
    api.execute_pick('select 1')
    restore()
    api.execute = original_execute
    assert.truthy(executed)
    assert.equals('select 1', executed.sql)
    assert.truthy(api.info(executed.name))
  end)

  it('surfaces an execute failure as an error notification', function()
    seed({ { name = 'dev', url = 'sqlite:/tmp/dev.db' } })
    local original_execute = api.execute
    ---@diagnostic disable-next-line: duplicate-set-field
    api.execute = function()
      return false, 'boom'
    end
    local _, restore = stub_select(function(items)
      return items[1]
    end)
    api.execute_pick('select 1')
    restore()
    api.execute = original_execute
    assert.equals('boom', notifications.get_last_msg())
  end)

  it('rejects empty sql before showing any picker', function()
    seed({ { name = 'dev', url = 'sqlite:/tmp/dev.db' } })
    local seen, restore = stub_select(nil)
    api.execute_pick('   ')
    restore()
    assert.is_false(seen.called)
    assert.equals('No sql to execute', notifications.get_last_msg())
  end)

  it('is a no-op on cancel', function()
    seed({ { name = 'dev', url = 'sqlite:/tmp/dev.db' } })
    local executed = false
    local original_execute = api.execute
    ---@diagnostic disable-next-line: duplicate-set-field
    api.execute = function()
      executed = true
      return true
    end
    local _, restore = stub_select(nil) -- cancel the pick
    api.execute_pick('select 1')
    restore()
    api.execute = original_execute
    assert.is_false(executed)
  end)
end)

describe('picker: explain_pick', function()
  after_each(function()
    vim.g.dbs = nil
    state.reset()
  end)

  -- Route explain_execute into a recorder; returns the record table + a restore.
  local function stub_explain_execute(result, err)
    local original = api.explain_execute
    local record = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    api.explain_execute = function(name, sql, opts)
      record.name, record.sql, record.opts = name, sql, opts
      return result, err
    end
    return record, function()
      api.explain_execute = original
    end
  end

  it('prompts for the variant, then explains against the picked connection', function()
    seed({ { name = 'dev', url = 'sqlite:/tmp/dev.db' } })
    local record, restore_explain = stub_explain_execute(true)
    local seen, restore = stub_select(function(items)
      -- variant prompt offers plain strings; the connection picker offers items
      return type(items[1]) == 'string' and 'EXPLAIN' or items[1]
    end)
    api.explain_pick('select 1')
    restore()
    restore_explain()
    assert.equals(2, #seen.calls) -- variant prompt, then connection picker
    assert.equals('EXPLAIN', seen.calls[1].items[1])
    assert.equals('select 1', record.sql)
    assert.is_false(record.opts.analyze)
    assert.truthy(api.info(record.name))
  end)

  it('skips the variant prompt when analyze is specified', function()
    seed({ { name = 'dev', url = 'sqlite:/tmp/dev.db' } })
    local record, restore_explain = stub_explain_execute(true)
    local seen, restore = stub_select(function(items)
      return items[1]
    end)
    api.explain_pick('select 1', { analyze = true })
    restore()
    restore_explain()
    assert.equals(1, #seen.calls) -- straight to the connection picker
    assert.is_true(record.opts.analyze)
  end)

  it('cancelling the variant prompt shows no picker', function()
    seed({ { name = 'dev', url = 'sqlite:/tmp/dev.db' } })
    local record, restore_explain = stub_explain_execute(true)
    local seen, restore = stub_select(nil) -- cancel the variant prompt
    api.explain_pick('select 1')
    restore()
    restore_explain()
    assert.equals(1, #seen.calls)
    assert.is_nil(record.sql)
  end)

  it('surfaces an unsupported-adapter error as a notification', function()
    seed({ { name = 'dev', url = 'sqlite:/tmp/dev.db' } })
    local _, restore_explain = stub_explain_execute(false, 'explain is not supported for scheme x')
    local _, restore = stub_select(function(items)
      return items[1]
    end)
    api.explain_pick('select 1', { analyze = false })
    restore()
    restore_explain()
    assert.equals('explain is not supported for scheme x', notifications.get_last_msg())
  end)

  it('rejects empty sql before showing any prompt', function()
    seed({ { name = 'dev', url = 'sqlite:/tmp/dev.db' } })
    local seen, restore = stub_select(nil)
    api.explain_pick('')
    restore()
    assert.is_false(seen.called)
    assert.equals('No sql to explain', notifications.get_last_msg())
  end)
end)

describe('picker: api surface', function()
  it('exposes the picker verbs and the picker config default', function()
    assert.equals('function', type(api.pick))
    assert.equals('function', type(api.execute_pick))
    assert.equals('function', type(api.explain_pick))
    assert.equals('auto', require('dadbod-ui.config').defaults.picker)
  end)
end)
