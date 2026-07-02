---@mod dadbod-ui.hooks  User-configurable lifecycle hooks
---
--- A tiny, dependency-injectable dispatch layer for the user hooks declared in
--- `config.hooks` (see `DadbodUI.Hooks`). Each hook is an optional function the
--- user supplies in `setup{}`; we call it at a well-defined point in the connect
--- / execute / cancel lifecycle with a typed event.
---
--- Two guarantees make this safe to sprinkle through the hot paths:
---   * **Isolation** -- every hook runs under `pcall`. A throwing hook is caught,
---     surfaced through `dadbod-ui.notifications` (respecting the notification
---     config), and swallowed, so it can never abort a connect / execute / cancel.
---   * **Transform** -- `on_connect` may rewrite the connection url. `run` returns
---     the hook's value verbatim; `transform` narrows it to a string (so a nil /
---     non-string return means "leave the url unchanged"), which the connect path
---     uses to swap a `$password` placeholder for a real secret before connecting.
---
--- Leaf module: it requires nothing from the project at load time and lazy-requires
--- `notifications` only on the error path, so the acyclic graph is preserved.

---@class DadbodUI.HooksModule
---@field run fun(config: DadbodUI.Config, name: string, event: DadbodUI.HookEvent): any
---@field transform fun(config: DadbodUI.Config, name: string, event: DadbodUI.HookEvent): string|nil

---@type DadbodUI.HooksModule
---@diagnostic disable-next-line: missing-fields
local M = {}

--- Invoke the hook named `name` (if configured) with `event`, isolated under
--- `pcall`. Returns the hook's return value on success, or nil when there is no
--- such hook or it threw (the error is notified, never propagated).
---@param config DadbodUI.Config
---@param name string  a key of `config.hooks` (e.g. 'on_connect')
---@param event DadbodUI.HookEvent
---@return any  the hook's return value, or nil (no hook / error)
function M.run(config, name, event)
  local hooks = config.hooks
  if type(hooks) ~= 'table' then
    return nil
  end
  local hook = hooks[name]
  if type(hook) ~= 'function' then
    return nil
  end
  local ok, result = pcall(hook, event)
  if not ok then
    require('dadbod-ui.notifications').error(string.format('Error in %s hook: %s', name, tostring(result)))
    return nil
  end
  return result
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

return M
