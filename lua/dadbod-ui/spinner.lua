-- Animated spinner timer registry
--
-- A leaf module: it knows nothing about buffers, the drawer, or the engine, and
-- requires nothing from the project (so it stays a sink-side leaf, like
-- `bind_params`). It owns a registry of NAMED timers so independent callers
-- (each result buffer, each loading db node) animate without stepping on each
-- other, and it animates whatever frame set the CALLER passes from the data
-- catalog `dadbod-ui.spinners` -- so different call sites pick different designs
-- (connections use `spinners.dots`; query results use `spinners.dots12`).
--
-- Callers drive a spinner with `start(key, frames, on_tick)` / `stop(key)`:
-- `on_tick` receives the current frame string immediately and then every
-- interval. The registry entry also carries the bare `tick` closure so specs can
-- advance a spinner deterministically (`_timers[key].tick()`) instead of sleeping.

---@alias DadbodUI.SpinnerOnTick fun(frame: string)

---@class DadbodUI.SpinnerModule
---@field DEFAULT_INTERVAL integer
---@field start fun(key: any, frames: string[], on_tick: DadbodUI.SpinnerOnTick, interval?: integer)
---@field stop fun(key: any)
---@field _timers table<any, { timer: uv.uv_timer_t, tick: fun(), scheduled: fun() }>  test seam: keyed registry (`tick` advances a frame, `scheduled` is the stop-guarded timer callback)
---@field _new_timer fun(): uv.uv_timer_t|nil  test seam: injectable timer constructor

---@type DadbodUI.SpinnerModule
---@diagnostic disable-next-line: missing-fields
local M = {}

-- The default per-frame interval in milliseconds. A caller may override it per
-- `start` (the cli-spinners note: tune the rate to the chosen frame count).
---@type integer
M.DEFAULT_INTERVAL = 80

-- key -> { timer = uv.uv_timer_t, tick = fun(): nil }. The registry is keyed so
-- multiple spinners run independently; `tick` advances one frame (used by the
-- timer and, in specs, called directly).
---@type table<any, { timer: uv.uv_timer_t, tick: fun(): nil, scheduled: fun(): nil }>
M._timers = {}

-- Injectable timer constructor (defaults to libuv); a spec may swap it for a
-- fake to assert lifecycle without the event loop.
---@type fun(): uv.uv_timer_t|nil
M._new_timer = vim.uv.new_timer

--- Start (or replace) the spinner for `key`, cycling `frames` in order. `on_tick`
--- is invoked immediately with the first frame, then with each subsequent frame
--- every `interval` ms (defaults to `DEFAULT_INTERVAL`). Replaces any spinner
--- already running for `key`.
---@param key any
---@param frames string[]  the frame set to cycle (e.g. `dadbod-ui.spinners`.dots)
---@param on_tick fun(frame: string): nil
---@param interval? integer  per-frame ms; defaults to `DEFAULT_INTERVAL`
---@return nil
function M.start(key, frames, on_tick, interval)
  M.stop(key)
  local timer = M._new_timer()
  if timer == nil then
    return
  end
  interval = interval or M.DEFAULT_INTERVAL
  local frame = 1
  local function tick()
    on_tick(frames[frame])
    frame = frame % #frames + 1
  end
  -- A tick scheduled via `vim.schedule_wrap` can still be pending on the loop
  -- when `stop` (or a replacing `start`) runs, and would then fire afterwards --
  -- repainting the spinner over results dadbod had already loaded. Guard the
  -- scheduled path on THIS start still being the registered one: a stale tick
  -- from a stopped/replaced spinner finds a different (or nil) registration and
  -- bails. Captured before the registration table so the closure can compare it.
  local registration
  local function scheduled()
    if M._timers[key] ~= registration then
      return
    end
    tick()
  end
  registration = { timer = timer, tick = tick, scheduled = scheduled }
  M._timers[key] = registration
  -- Paint the first frame synchronously so it shows before the loop yields;
  -- subsequent ticks are scheduled (a uv timer callback can't touch the API).
  tick()
  timer:start(interval, interval, vim.schedule_wrap(scheduled))
end

--- Stop, close and forget the spinner for `key`. Idempotent and pcall-guarded:
--- safe to call when no spinner is running, or twice (same discipline dbout used).
---@param key any
---@return nil
function M.stop(key)
  local s = M._timers[key]
  if s == nil then
    return
  end
  M._timers[key] = nil
  pcall(function()
    s.timer:stop()
    if not s.timer:is_closing() then
      s.timer:close()
    end
  end)
end

return M
