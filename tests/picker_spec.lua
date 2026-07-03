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
-- the (items, opts) it was shown and picks via `choose(items)` (nil = cancel).
local function stub_select(choose)
  local original = vim.ui.select
  local seen = { called = false }
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.ui.select = function(items, opts, on_choice)
    seen.called = true
    seen.items = items
    seen.opts = opts
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

describe('picker: api surface', function()
  it('exposes api.pick and the picker config default', function()
    assert.equals('function', type(api.pick))
    assert.equals('auto', require('dadbod-ui.config').defaults.picker)
  end)
end)
