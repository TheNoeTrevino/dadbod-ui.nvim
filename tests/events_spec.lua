-- Specs for the runtime event bus (`dadbod-ui.events`, exposed as api.on/off):
-- registration + removal, unknown-event rejection, listener isolation, and the
-- integration point where `hooks.run` fans an event out to bus listeners AND the
-- config hook together. Pure dispatch -- no drawer or live DB.

local events = require('dadbod-ui.events')
local hooks = require('dadbod-ui.hooks')
local notifications = require('dadbod-ui.notifications')

describe('events: registration', function()
  after_each(function()
    events.clear()
  end)

  it('delivers an emitted payload to a subscribed listener', function()
    local seen
    events.on('on_connect_post', function(ev)
      seen = ev
    end)
    events.emit('on_connect_post', { url = 'u', success = true })
    assert.equals('u', seen.url)
    assert.is_true(seen.success)
  end)

  it('supports multiple listeners on the same event', function()
    local hits = 0
    events.on('on_execute_query', function()
      hits = hits + 1
    end)
    events.on('on_execute_query', function()
      hits = hits + 1
    end)
    events.emit('on_execute_query', {})
    assert.equals(2, hits)
  end)

  it('rejects an unknown event name with an error, no handle', function()
    local h, err = events.on('on_bogus', function() end)
    assert.is_nil(h)
    assert.is_truthy(err and err:find('unknown event'))
  end)

  it('rejects a non-function listener', function()
    local h, err = events.on('on_connect', 'nope')
    assert.is_nil(h)
    assert.is_truthy(err and err:find('function'))
  end)

  it('off removes exactly the handle it is given', function()
    local hits = 0
    local h1 = events.on('on_cancel_query', function()
      hits = hits + 1
    end)
    events.on('on_cancel_query', function()
      hits = hits + 1
    end)
    assert.is_true(events.off(h1))
    events.emit('on_cancel_query', {})
    assert.equals(1, hits) -- only the second listener remains
  end)

  it('off returns false for a stale or foreign handle', function()
    local h = events.on('on_connect', function() end)
    assert.is_true(events.off(h))
    assert.is_false(events.off(h)) -- already gone
    assert.is_false(events.off({ event = 'on_connect', id = 999 }))
    assert.is_false(events.off('not a handle'))
  end)

  it('has reports whether anyone is listening', function()
    assert.is_false(events.has('on_execute_query_post'))
    local h = events.on('on_execute_query_post', function() end)
    assert.is_true(events.has('on_execute_query_post'))
    events.off(h)
    assert.is_false(events.has('on_execute_query_post'))
  end)

  it('isolates a throwing listener: others still fire, error is notified', function()
    local reached
    events.on('on_connect', function()
      error('boom')
    end)
    events.on('on_connect', function()
      reached = true
    end)
    events.emit('on_connect', {})
    assert.is_true(reached)
    assert.is_truthy(notifications.get_last_msg():find('on_connect'))
  end)
end)

describe('events: hooks.run integration', function()
  after_each(function()
    events.clear()
  end)

  it('fans an event to bus listeners AND the config hook', function()
    local hook_saw, bus_saw
    local cfg = {
      hooks = {
        on_connect_post = function(e)
          hook_saw = e.url
        end,
      },
    }
    events.on('on_connect_post', function(e)
      bus_saw = e.url
    end)
    hooks.run(cfg, 'on_connect_post', { url = 'shared' })
    assert.equals('shared', hook_saw)
    assert.equals('shared', bus_saw)
  end)

  it('emits to the bus even when no config hook is set', function()
    local bus_saw
    events.on('on_execute_query', function(e)
      bus_saw = e.sql
    end)
    hooks.run({ hooks = {} }, 'on_execute_query', { sql = 'select 1' })
    assert.equals('select 1', bus_saw)
  end)

  it('bus listeners are observers: on_connect url rewrite stays the config hook', function()
    -- A bus listener returning a string must NOT rewrite the url; only the config
    -- hook (via transform) can.
    events.on('on_connect', function()
      return 'bus://rewrite'
    end)
    local cfg = {
      hooks = {
        on_connect = function()
          return 'hook://rewrite'
        end,
      },
    }
    assert.equals('hook://rewrite', hooks.transform(cfg, 'on_connect', { url = 'u' }))
  end)

  it('hooks.has is true when only a bus listener exists', function()
    local cfg = { hooks = {} }
    assert.is_false(hooks.has(cfg, 'on_execute_query_post'))
    events.on('on_execute_query_post', function() end)
    assert.is_true(hooks.has(cfg, 'on_execute_query_post'))
  end)
end)
