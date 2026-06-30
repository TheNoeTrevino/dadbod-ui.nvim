---@mod dadbod-ui.mappings  The single source of truth for keybindings + help
---
--- Keys, descriptions and ordering live in `config.mappings` (overridable per
--- entry) and the `config.mapping_order` / `config.mapping_sections` constants
--- (fixed). Each owning module (`drawer`, `query`, `dbout`) supplies a table of
--- handlers keyed by the same action ids; `apply` binds them and `help_lines`
--- renders the floating help window from the very same data, so the two can
--- never drift.
---
--- An entry's `key` is a string, a list of strings (aliases), or the literal
--- `'none'` to disable the action -- a disabled action is neither bound nor
--- shown in help. `mode` (string or list, default `'n'`) is the mode(s) the
--- key(s) bind in. The rare action that needs different keys per mode carries an
--- explicit `binds` list of `{ mode, lhs }` (used for binding; `key` still drives
--- the help display).

local M = {}

--- An action is disabled when it is missing or its key is the `'none'` sentinel.
---@param entry? DadbodUI.Mapping
---@return boolean
function M.is_disabled(entry)
  return entry == nil or entry.key == nil or entry.key == 'none'
end

--- The concrete `{ mode, lhs }` bindings for an entry (empty when disabled).
---@param entry? DadbodUI.Mapping
---@return { mode: string, lhs: string }[]
function M.binds(entry)
  if M.is_disabled(entry) then
    return {}
  end
  ---@cast entry DadbodUI.Mapping
  if entry.binds then
    return entry.binds
  end
  local keys = type(entry.key) == 'table' and entry.key or { entry.key }
  local mode = entry.mode or 'n'
  local modes = type(mode) == 'table' and mode or { mode }
  local out = {}
  for _, m in ipairs(modes) do
    for _, lhs in ipairs(keys) do
      out[#out + 1] = { mode = m, lhs = lhs }
    end
  end
  return out
end

--- The key string shown in the help window (aliases joined with ` / `).
---@param entry DadbodUI.Mapping
---@return string
function M.display_key(entry)
  local keys = type(entry.key) == 'table' and entry.key or { entry.key }
  return table.concat(keys, ' / ')
end

--- Bind every (non-disabled) action of `group` whose id has a handler. The
--- handler is invoked with the triggering mode so one entry can serve several
--- modes (e.g. normal vs visual execute). `opts` are passed through to
--- `vim.keymap.set` (the caller supplies `buffer`).
---@param group table<string, DadbodUI.Mapping>  the resolved config.mappings[ctx]
---@param order string[]  config.mapping_order[ctx]
---@param handlers table<string, fun(mode: string)>
---@param opts table  vim.keymap.set options (must include `buffer`)
---@return nil
function M.apply(group, order, handlers, opts)
  for _, id in ipairs(order) do
    local entry = group[id]
    local handler = handlers[id]
    if handler ~= nil and not M.is_disabled(entry) then
      for _, b in ipairs(M.binds(entry)) do
        vim.keymap.set(b.mode, b.lhs, function()
          handler(b.mode)
        end, opts)
      end
    end
  end
end

--- The sectioned, key-aligned line list for the floating help window, built from
--- the resolved `config`. Sections with no visible mappings are omitted; a blank
--- line separates the rendered sections.
---@param config DadbodUI.Config
---@return string[]
function M.help_lines(config)
  local cfg = require('dadbod-ui.config')
  local sections = {}
  local key_width = 0
  for _, sec in ipairs(cfg.mapping_sections) do
    local group = config.mappings[sec.group] or {}
    local rows = {}
    for _, id in ipairs(cfg.mapping_order[sec.group]) do
      local entry = group[id]
      if not M.is_disabled(entry) then
        local key = M.display_key(entry)
        if #key > key_width then
          key_width = #key
        end
        rows[#rows + 1] = { key = key, desc = entry.desc }
      end
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
