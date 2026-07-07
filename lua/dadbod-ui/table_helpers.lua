-- Table-helper resolution (merge + ordering)
--
-- Each adapter maps a helper name (`List`, `Columns`, `Indexes`, ...) to a SQL
-- template containing placeholders (`{table}`, `{schema}`, `{optional_schema}`,
-- ...). The templates live on the adapter specs (`dadbod-ui.adapters`); this
-- module owns the behavior only: merging the adapter defaults with the user's
-- `config.table_helpers` overrides, and the deterministic display order.

---@class DadbodUI.TableHelpersModule
---@field get fun(scheme: string, config?: DadbodUI.Config): table<string, string>
---@field ordered_names fun(helper_map: table<string, string>, order?: string[]): string[]

---@private
local adapters = require('dadbod-ui.adapters')

---@type DadbodUI.TableHelpersModule
---@diagnostic disable-next-line: missing-fields
local M = {}

--- The helper map for `scheme`, merged with user overrides: the adapter defaults
--- are overlaid with `config.table_helpers[<name>]` for every name the adapter
--- answers to (aliases first, the connection's ACTUAL scheme last, so an exact
--- override always wins over one keyed by an alias), helpers set to the empty
--- string are dropped, and an all-empty result falls back to a blank `List` so a
--- table always renders at least one child.
---@param scheme string
---@param config? DadbodUI.Config
---@return table<string, string>
function M.get(scheme, config)
  config = config or { query = { default_query = 'SELECT * from "{table}" LIMIT 200;' }, table_helpers = {} }
  local user = config.table_helpers or {}

  local spec = adapters.get(scheme)
  local base = spec and spec.table_helpers or nil
  if type(base) == 'function' then
    base = base(config)
  end

  local result = vim.tbl_extend('force', {}, base or { List = '' })
  if spec ~= nil then
    -- Overrides keyed by the canonical name or any alias apply; the raw scheme's
    -- own overrides are merged LAST so they win over the alias-keyed ones.
    for _, name in ipairs(vim.list_extend({ spec.name }, spec.aliases or {})) do
      if name ~= scheme then
        result = vim.tbl_extend('force', result, user[name] or {})
      end
    end
  end
  result = vim.tbl_extend('force', result, user[scheme] or {})

  for key, value in pairs(result) do
    if value == '' then
      result[key] = nil
    end
  end

  if vim.tbl_isempty(result) then
    result.List = ''
  end

  return result
end

---@private
-- Canonical display order for table helpers. `List` always comes first; the
-- rest follow a fixed, schema-independent sequence. Names not listed here
-- (adapter extras like `Constraints`/`Describe`, and any user-added helper)
-- sort alphabetically after these, so the drawer order is fully deterministic
-- regardless of `pairs()` iteration order.
local helper_order = { 'List', 'Columns', 'Indexes', 'Primary Keys', 'Foreign Keys', 'References' }

--- The names in `helper_map`, ordered for display: `order` first (only names
--- actually present in `helper_map`, in `order` sequence -- names absent from
--- `helper_map` are skipped, no blank nodes), then any remaining present
--- helpers (adapter extras, or user-added helpers not named in `order`)
--- alphabetically, so the tail stays deterministic regardless of `pairs()`
--- iteration order. `order` defaults to the module's canonical sequence, so
--- existing callers (and the default `table_helpers_order` config) are
--- unaffected; an empty or all-unknown `order` degrades gracefully to "every
--- present helper, alphabetically".
---@param helper_map table<string, string>
---@param order? string[]
---@return string[]
function M.ordered_names(helper_map, order)
  order = order or helper_order
  local is_ordered = {} -- name -> true, for the "already placed by `order`" test
  for _, name in ipairs(order) do
    is_ordered[name] = true
  end
  -- Names from `order` that are present, kept in `order` sequence.
  local ordered = vim
    .iter(order)
    :filter(function(name)
      return helper_map[name] ~= nil
    end)
    :totable()
  -- Everything else (adapter extras, user-added helpers not named in `order`),
  -- sorted alphabetically.
  local extras = vim
    .iter(vim.tbl_keys(helper_map))
    :filter(function(name)
      return not is_ordered[name]
    end)
    :totable()
  table.sort(extras)
  return vim.list_extend(ordered, extras)
end

return M
