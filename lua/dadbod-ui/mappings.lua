-- The single source of truth for keybindings + help
--
-- Each context (`drawer`, `query`, `results`) carries a `keys` map of
-- `lhs -> action` in the resolved config, plus the fixed presentation metadata in
-- `config` (`contexts`, `builtin_actions`, `action_order`). The owning module
-- (`drawer`, `query`, `dbout`) supplies a table of built-in handlers keyed by
-- action id and a `make_ctx` builder for user actions; `apply` binds the keys and
-- `help_lines` renders the floating help window from the very same `keys` map, so
-- the two can never drift.
--
-- A `keys` value is an action name (a built-in id or a key in `config.actions`),
-- `{ '<action>', mode = ... }` to bind specific mode(s) (default `'n'`), or
-- `false` to disable that key. A whole `keys` table set to `false` disables the
-- context. A name with no built-in handler and no `config.actions` entry is
-- skipped (neither bound nor shown in help).

---@class DadbodUI.MappingsModule
---@field normalize fun(spec: DadbodUI.KeySpec): { action: string, modes: string[] }|nil
---@field apply fun(keys: DadbodUI.Keymaps, handlers: table<string, fun(mode: string)>, actions: table<string, DadbodUI.Action>, make_ctx: fun(mode: string): DadbodUI.ActionContext, opts: table)
---@field help_lines fun(config: DadbodUI.Config): string[]
---@field keys_for_action fun(keys: DadbodUI.Keymaps, action: string): string

---@type DadbodUI.MappingsModule
---@diagnostic disable-next-line: missing-fields
local M = {}

--- Normalize a `keys` value to `{ action, modes }`, or nil when disabled
--- (`false`/`nil`). A bare string binds action in normal mode; a table's `[1]` is
--- the action and `mode` (string or list, default `'n'`) the mode(s).
---@param spec DadbodUI.KeySpec
---@return { action: string, modes: string[] }|nil
function M.normalize(spec)
  if spec == nil or spec == false then
    return nil
  end
  if type(spec) == 'string' then
    return { action = spec, modes = { 'n' } }
  end
  local mode = spec.mode or 'n'
  return { action = spec[1], modes = type(mode) == 'table' and mode or { mode } }
end

--- Resolve an action name to its function: a built-in handler (called with the
--- triggering mode), or a `config.actions` entry (called with the action context).
--- Returns `fn, is_user` or nil when the name is unknown.
---@param name string
---@param handlers table<string, fun(mode: string)>
---@param actions table<string, DadbodUI.Action>
---@return (fun(arg: any))?, boolean?
local function resolve(name, handlers, actions)
  local builtin = handlers[name]
  if builtin ~= nil then
    return builtin, false
  end
  local user = actions and actions[name]
  if user ~= nil then
    return type(user) == 'function' and user or user.fn, true
  end
  return nil
end

--- Bind every enabled key in `keys` whose action resolves to a handler. Built-in
--- handlers are invoked with the triggering mode; user actions with
--- `make_ctx(mode)`. `opts` are passed through to `vim.keymap.set` (the caller
--- supplies `buffer`). A `false` `keys` table (context disabled) binds nothing.
---@param keys DadbodUI.Keymaps
---@param handlers table<string, fun(mode: string)>
---@param actions table<string, DadbodUI.Action>
---@param make_ctx fun(mode: string): DadbodUI.ActionContext
---@param opts table
---@return nil
function M.apply(keys, handlers, actions, make_ctx, opts)
  if type(keys) ~= 'table' then
    return
  end
  for lhs, spec in pairs(keys) do
    local norm = M.normalize(spec)
    if norm ~= nil then
      local fn, is_user = resolve(norm.action, handlers, actions)
      if fn ~= nil then
        for _, mode in ipairs(norm.modes) do
          vim.keymap.set(mode, lhs, function()
            fn(is_user and make_ctx(mode) or mode)
          end, opts)
        end
      end
    end
  end
end

--- Invert a `keys` map to `action -> sorted lhs list`, skipping disabled entries.
---@param keys DadbodUI.Keymaps
---@return table<string, string[]>
local function by_action(keys)
  local out = {}
  if type(keys) ~= 'table' then
    return out
  end
  for lhs, spec in pairs(keys) do
    local norm = M.normalize(spec)
    if norm ~= nil then
      out[norm.action] = out[norm.action] or {}
      table.insert(out[norm.action], lhs)
    end
  end
  for _, list in pairs(out) do
    table.sort(list)
  end
  return out
end

--- The display key string for an action (its bound lhs values joined with ` / `),
--- or `''` when the action is unbound. Used by the result winbar's page-nav hint.
---@param keys DadbodUI.Keymaps
---@param action string
---@return string
function M.keys_for_action(keys, action)
  local list = by_action(keys)[action]
  return list and table.concat(list, ' / ') or ''
end

--- The description shown for an action: the built-in help text, a user action's
--- `desc`, or the action name as a last resort.
---@param ctx string  the context group ('drawer'|'query'|'results')
---@param action string
---@param config DadbodUI.Config
---@return string
local function describe(ctx, action, config)
  local builtin = require('dadbod-ui.config').builtin_actions[ctx]
  if builtin and builtin[action] then
    return builtin[action]
  end
  local user = config.actions and config.actions[action]
  if type(user) == 'table' and user.desc then
    return user.desc
  end
  return action
end

--- The sectioned, key-aligned line list for the floating help window, built from
--- the resolved `config`. Built-in actions render first (in `action_order`), then
--- any user actions bound in a context's `keys`, sorted by name. Sections with no
--- visible mappings are omitted; a blank line separates the rendered sections.
---@param config DadbodUI.Config
---@return string[]
function M.help_lines(config)
  local cfg = require('dadbod-ui.config')
  local sections = {}
  local key_width = 0

  for _, sec in ipairs(cfg.contexts) do
    local keys = config[sec.group] and config[sec.group].keys
    local bound = by_action(keys)

    -- Built-in actions in their fixed order, then user actions (any bound action
    -- not covered by the built-in order) alphabetically.
    local order = {}
    local seen = {}
    for _, id in ipairs(cfg.action_order[sec.group] or {}) do
      if bound[id] then
        order[#order + 1] = id
        seen[id] = true
      end
    end
    local extras = {}
    for id in pairs(bound) do
      if not seen[id] then
        extras[#extras + 1] = id
      end
    end
    table.sort(extras)
    vim.list_extend(order, extras)

    local rows = {}
    for _, id in ipairs(order) do
      local key = table.concat(bound[id], ' / ')
      if #key > key_width then
        key_width = #key
      end
      rows[#rows + 1] = { key = key, desc = describe(sec.group, id, config) }
    end
    if #rows > 0 then
      sections[#sections + 1] = { title = sec.title, rows = rows }
    end
  end

  local lines = {}
  local fmt = '  %-' .. key_width .. 's  %s'
  for _, sec in ipairs(sections) do
    if #lines > 0 then
      lines[#lines + 1] = ''
    end
    lines[#lines + 1] = sec.title
    for _, r in ipairs(sec.rows) do
      lines[#lines + 1] = string.format(fmt, r.key, r.desc)
    end
  end
  return lines
end

return M
