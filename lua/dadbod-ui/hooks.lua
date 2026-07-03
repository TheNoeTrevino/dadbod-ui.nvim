-- User-configurable lifecycle hooks
--
-- A tiny, dependency-injectable dispatch layer for the user hooks declared in
-- `config.hooks` (see `DadbodUI.Hooks`). Each hook is an optional function the
-- user supplies in `setup{}`; we call it at a well-defined point in the connect
-- / execute / cancel lifecycle with a typed event.
--
-- Two guarantees make this safe to sprinkle through the hot paths:
--   * **Isolation** -- every hook runs under `pcall`. A throwing hook is caught,
--     surfaced through `dadbod-ui.notifications` (respecting the notification
--     config), and swallowed, so it can never abort a connect / execute / cancel.
--   * **Transform** -- `on_connect` may rewrite the connection url. `run` returns
--     the hook's value verbatim; `transform` narrows it to a string (so a nil /
--     non-string return means "leave the url unchanged"), which the connect path
--     uses to swap a `$password` placeholder for a real secret before connecting.
--
-- Leaf module: it requires nothing from the project at load time and lazy-requires
-- `notifications` only on the error path, so the acyclic graph is preserved.

---@class DadbodUI.HooksModule
---@field run fun(config: DadbodUI.Config, name: string, event: DadbodUI.HookEvent): any
---@field call fun(config: DadbodUI.Config, name: string, ...: any): any
---@field transform fun(config: DadbodUI.Config, name: string, event: DadbodUI.HookEvent): string|nil
---@field has fun(config: DadbodUI.Config, name: string): boolean

---@type DadbodUI.HooksModule
---@diagnostic disable-next-line: missing-fields
local M = {}

--- Invoke the hook named `name` with `event`, then fan the same event out to any
--- runtime listeners registered via `dadbod-ui.api.on` (see `dadbod-ui.events`).
--- The config hook (if any) runs first, isolated under `pcall`; its return value
--- is what `run` returns (so `transform` still sees only the config hook -- bus
--- listeners are observers and cannot rewrite the url). A missing config hook is a
--- clean no-op that still emits to the bus, so `api.on` works with no `setup{}` hook.
---@param config DadbodUI.Config
---@param name string  a key of `config.hooks` (e.g. 'on_connect')
---@param event DadbodUI.HookEvent
---@return any  the config hook's return value, or nil (no hook / error)
function M.run(config, name, event)
  local result = nil
  local hooks = config.hooks
  if type(hooks) == 'table' and type(hooks[name]) == 'function' then
    local ok, ret = pcall(hooks[name], event)
    if ok then
      result = ret
    else
      require('dadbod-ui.notifications').error(string.format('Error in %s hook: %s', name, tostring(ret)))
    end
  end
  require('dadbod-ui.events').emit(name, event)
  return result
end

--- Invoke the config hook `name` with `...` (a plain arg list, not a single event),
--- isolated under `pcall`, and return its raw value. Unlike `run`, this does NOT
--- emit to the event bus -- it is for data-plane hooks (e.g. bind-param resolution)
--- that compute a VALUE the caller consumes, rather than announce a lifecycle
--- moment observers might watch. A missing hook, or one that throws (caught and
--- notified), returns nil, so the caller degrades cleanly to its default behavior.
---@param config DadbodUI.Config
---@param name string  a key of `config.hooks` (e.g. 'resolve_bind_params')
---@param ... any  the hook's arguments
---@return any  the hook's return value, or nil (no hook / error)
function M.call(config, name, ...)
  local hooks = config.hooks
  if type(hooks) ~= 'table' or type(hooks[name]) ~= 'function' then
    return nil
  end
  local ok, ret = pcall(hooks[name], ...)
  if not ok then
    require('dadbod-ui.notifications').error(string.format('Error in %s hook: %s', name, tostring(ret)))
    return nil
  end
  return ret
end

--- Run a transform hook and narrow its result to a string. A string return is the
--- rewritten value; anything else (nil, a non-string, or a thrown-and-caught hook)
--- yields nil, meaning "unchanged". Used by the connect path for `on_connect`.
---@param config DadbodUI.Config
---@param name string  a key of `config.hooks` (e.g. 'on_connect')
---@param event DadbodUI.HookEvent
---@return string|nil  the rewritten string, or nil when unchanged
function M.transform(config, name, event)
  local result = M.run(config, name, event)
  if type(result) == 'string' then
    return result
  end
  return nil
end

--- Whether anyone is listening for `name` -- either a `config.hooks` function OR a
--- runtime `api.on` listener. Fire sites that do extra work only to feed a hook
--- (e.g. the lazy result read for `on_execute_query_post`) guard on this so they
--- pay nothing when nobody is watching.
---@param config DadbodUI.Config
---@param name string
---@return boolean
function M.has(config, name)
  if type(config.hooks) == 'table' and type(config.hooks[name]) == 'function' then
    return true
  end
  return require('dadbod-ui.events').has(name)
end

return M
