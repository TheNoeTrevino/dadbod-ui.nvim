-- Specs for the named spinner timer registry. Drives the registry directly (and
-- the registry's per-entry `tick`) so frame advancement is asserted
-- deterministically, without sleeping on the event loop. The frame sets live in
-- `dadbod-ui.spinners`; the registry animates whatever the caller passes.

local spinner = require('dadbod-ui.spinner')
local spinners = require('dadbod-ui.spinners')

describe('spinner: default interval', function()
  it('defaults to 80ms', function()
    assert.equals(80, spinner.DEFAULT_INTERVAL)
  end)
end)

describe('spinner: start/stop lifecycle', function()
  local frames = spinners.dots -- the connection-loading set

  after_each(function()
    spinner.stop('a')
    spinner.stop('b')
  end)

  it('invokes on_tick immediately with the first frame', function()
    local seen = {}
    spinner.start('a', frames, function(frame)
      seen[#seen + 1] = frame
    end)
    assert.same({ frames[1] }, seen)
    assert.is_not_nil(spinner._timers['a'])
  end)

  it('advances frames in order on each tick', function()
    local seen = {}
    spinner.start('a', frames, function(frame)
      seen[#seen + 1] = frame
    end)
    spinner._timers['a'].tick()
    spinner._timers['a'].tick()
    assert.same({ frames[1], frames[2], frames[3] }, seen)
  end)

  it('wraps back to the first frame after the last', function()
    local seen = {}
    spinner.start('a', frames, function(frame)
      seen[#seen + 1] = frame
    end)
    for _ = 1, #frames do -- already painted frame 1, so this lands back on 1
      spinner._timers['a'].tick()
    end
    assert.equals(frames[1], seen[#seen])
  end)

  it('stop halts the timer and is idempotent', function()
    spinner.start('a', frames, function() end)
    assert.is_not_nil(spinner._timers['a'])
    spinner.stop('a')
    assert.is_nil(spinner._timers['a'])
    assert.has_no.errors(function()
      spinner.stop('a')
    end)
  end)

  it('start replaces a running spinner for the same key', function()
    spinner.start('a', frames, function() end)
    local first = spinner._timers['a']
    spinner.start('a', frames, function() end)
    assert.is_not_nil(spinner._timers['a'])
    assert.are_not.equal(first, spinner._timers['a'])
  end)

  it('animates two keys with independent (and possibly different) frame sets', function()
    local a, b = {}, {}
    spinner.start('a', spinners.dots, function(frame)
      a[#a + 1] = frame
    end)
    spinner.start('b', spinners.dots12, function(frame)
      b[#b + 1] = frame
    end)
    spinner._timers['a'].tick() -- only 'a' advances
    assert.same({ spinners.dots[1], spinners.dots[2] }, a)
    assert.same({ spinners.dots12[1] }, b)
  end)
end)
