-- Runtime event bus for lifecycle observers
--
-- The config `hooks` (see `DadbodUI.Hooks`) are single-slot and set once at
-- `setup{}` -- exactly one `on_connect_post`, and whoever claims it owns it. This
-- module is the multi-subscriber dual: any number of listeners can observe the
-- SAME lifecycle events at runtime, added and removed on the fly, without owning
-- the config slot. It backs `dadbod-ui.api.on` / `.off`.
--
-- The two surfaces meet in `dadbod-ui.hooks`: `hooks.run` invokes the config hook
-- AND fans the event out to every listener registered here (`emit`), so a single
-- fire feeds both. Listeners are OBSERVERS only -- unlike the `on_connect` config
-- hook, a bus listener cannot rewrite the connection url (its return is ignored).
--
-- Leaf module: requires nothing from the project at load time, lazy-requiring
-- `notifications` only on a listener's error path, so the acyclic graph holds.

---@alias DadbodUI.EventName
---| '"on_connect"'  before a connect (observer; url rewrite is config-hook only)
---| '"on_connect_post"'  after a connect (event carries success/conn/error)
---| '"on_execute_query"'  before SQL is dispatched
---| '"on_execute_query_post"'  after a result lands (event.rows() reads lazily)
---| '"on_cancel_query"'  before a running query is cancelled
---| '"on_cancel_query_post"'  after a running query is cancelled

---@class DadbodUI.EventHandle
---@field event DadbodUI.EventName
---@field id integer

---@class DadbodUI.EventsModule
---@field EVENTS table<string, boolean>
---@field valid fun(event: string): boolean
---@field on fun(event: DadbodUI.EventName, cb: fun(event: DadbodUI.HookEvent)): DadbodUI.EventHandle|nil, string|nil
---@field off fun(handle: DadbodUI.EventHandle): boolean
---@field has fun(event: string): boolean
---@field emit fun(event: string, payload: DadbodUI.HookEvent)
---@field clear fun()

---@type DadbodUI.EventsModule
---@diagnostic disable-next-line: missing-fields
local M = {}

--- The events a listener may subscribe to -- the same names as the config
--- `hooks`, so `emit(name)` maps 1:1 with `hooks.run(config, name, ...)`.
M.EVENTS = {
  on_connect = true,
  on_connect_post = true,
  on_execute_query = true,
  on_execute_query_post = true,
  on_cancel_query = true,
  on_cancel_query_post = true,
}

--- `event -> { [id] = cb }`. A map (not an array) so `off` is an O(1) delete that
--- never shifts other listeners' handles.
---@private
---@type table<string, table<integer, function>>
local listeners = {}

---@private
---@type integer  monotonic handle id (avoids `Date`/`random`, unavailable here)
local next_id = 0

--- Whether `event` is a subscribable event name.
---@param event string
---@return boolean
function M.valid(event)
  return M.EVENTS[event] == true
end

--- Register `cb` to observe `event`, returning a handle for `off`. Returns
--- `nil, err` for an unknown event name (a typo would otherwise never fire).
---@param event DadbodUI.EventName
---@param cb fun(event: DadbodUI.HookEvent)
---@return DadbodUI.EventHandle|nil, string|nil
function M.on(event, cb)
  if not M.valid(event) then
    return nil, 'unknown event: ' .. tostring(event)
  end
  if type(cb) ~= 'function' then
    return nil, 'listener must be a function'
  end
  next_id = next_id + 1
  listeners[event] = listeners[event] or {}
  listeners[event][next_id] = cb
  return { event = event, id = next_id }
end

--- Remove the listener a `handle` (from `on`) refers to. Returns whether one was
--- actually removed (false for a stale/foreign handle).
---@param handle DadbodUI.EventHandle
---@return boolean
function M.off(handle)
  if type(handle) ~= 'table' then
    return false
  end
  local bucket = listeners[handle.event]
  if bucket == nil or bucket[handle.id] == nil then
    return false
  end
  bucket[handle.id] = nil
  return true
end

--- Whether any listener is registered for `event`. Used by the execute-post fire
--- site to skip its lazy result read when nobody (config hook OR bus) is watching.
---@param event string
---@return boolean
function M.has(event)
  local bucket = listeners[event]
  return bucket ~= nil and next(bucket) ~= nil
end

--- Fan `payload` out to every listener of `event`, each isolated under `pcall` so
--- one throwing listener never disturbs the others or the lifecycle that emitted.
---@param event string
---@param payload DadbodUI.HookEvent
---@return nil
function M.emit(event, payload)
  local bucket = listeners[event]
  if bucket == nil then
    return
  end
  for _, cb in pairs(bucket) do
    local ok, err = pcall(cb, payload)
    if not ok then
      require('dadbod-ui.notifications').error(string.format('Error in %s listener: %s', event, tostring(err)))
    end
  end
end

--- Drop every listener. For tests/cleanup.
function M.clear()
  listeners = {}
  next_id = 0
end

return M
