-- Specs for the user-configurable hooks system (issue #20): the pure dispatch
-- module (run/transform, isolation, string narrowing) plus the six wired hooks
-- (connect pre/post, execute pre/post, cancel pre/post). Everything is driven by
-- dependency injection -- an injected connector spy, stubbed bridge functions,
-- and config carrying spy hooks -- so no live DB is touched.

local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')
local hooks = require('dadbod-ui.hooks')
local notifications = require('dadbod-ui.notifications')
local bridge = require('dadbod-ui.bridge')
local dbout = require('dadbod-ui.dbout')

local function make_drawer(g_dbs, overrides)
  local cfg =
    config.resolve(vim.tbl_extend('force', { save_location = '/tmp/dbui_hooks', show_help = false }, overrides or {}))
  local instance = state.new(cfg):populate({ env = {}, g_dbs = g_dbs, file_entries = {} })
  local d = drawer_mod.new(instance)
  d.connector = function(url)
    return url
  end
  return d
end

local function entry_named(d, name)
  for _, record in ipairs(d.instance.dbs_list) do
    if record.name == name then
      return d.instance.dbs[record.key_name]
    end
  end
end

-- The dispatch module in isolation -----------------------------------------

describe('hooks: run', function()
  it('returns nil when the named hook is not configured', function()
    assert.is_nil(hooks.run({ hooks = {} }, 'on_connect', {}))
  end)

  it('returns nil when there is no hooks table at all', function()
    assert.is_nil(hooks.run({}, 'on_connect', {}))
  end)

  it('calls the hook with the event and returns its value', function()
    local seen
    local cfg = {
      hooks = {
        on_connect = function(e)
          seen = e
          return 'ret'
        end,
      },
    }
    assert.equals('ret', hooks.run(cfg, 'on_connect', { url = 'u' }))
    assert.equals('u', seen.url)
  end)

  it('catches a throwing hook, notifies, and returns nil (never propagates)', function()
    local cfg = {
      hooks = {
        on_connect = function()
          error('boom')
        end,
      },
    }
    assert.is_nil(hooks.run(cfg, 'on_connect', {}))
    assert.is_truthy(notifications.get_last_msg():find('on_connect'))
  end)
end)

describe('hooks: transform', function()
  it('returns a string result verbatim', function()
    local cfg = {
      hooks = {
        on_connect = function()
          return 'rewritten'
        end,
      },
    }
    assert.equals('rewritten', hooks.transform(cfg, 'on_connect', {}))
  end)

  it('narrows a non-string return to nil (unchanged)', function()
    local cfg = {
      hooks = {
        on_connect = function()
          return 42
        end,
      },
    }
    assert.is_nil(hooks.transform(cfg, 'on_connect', {}))
  end)

  it('returns nil when the hook is absent', function()
    assert.is_nil(hooks.transform({ hooks = {} }, 'on_connect', {}))
  end)

  it('returns nil when the hook throws', function()
    local cfg = {
      hooks = {
        on_connect = function()
          error('nope')
        end,
      },
    }
    assert.is_nil(hooks.transform(cfg, 'on_connect', {}))
  end)
end)

-- Config surface ------------------------------------------------------------

describe('hooks: config', function()
  it('defaults to an empty hooks table', function()
    assert.same({}, config.resolve().hooks)
  end)

  it('keeps hook functions through the deep merge', function()
    local fn = function() end
    local cfg = config.resolve({ hooks = { on_connect = fn } })
    assert.equals(fn, cfg.hooks.on_connect)
  end)
end)

-- Connect path (on_connect / on_connect_post) -------------------------------
