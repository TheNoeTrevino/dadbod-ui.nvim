-- The adapter registry: one spec per database, indexed by every scheme name
--
-- The single source of per-adapter data. Each `adapters/<name>.lua` file is a
-- complete `DadbodUI.Adapter` spec -- introspection SQL, table helpers, explain
-- templates, pagination style, export flags -- registered here under its
-- canonical name AND its url-scheme aliases (postgresql -> postgres,
-- sqlite3 -> sqlite). The capability modules (`schemas`, `table_helpers`,
-- `explain`, `paginator`, `export.adapters`) own behavior only and read their
-- data through `get`, so aliasing is resolved exactly once, here.
--
-- `register` is public: a user (or plugin) adds a custom adapter with one call
-- and every capability picks it up -- `require('dadbod-ui.api').register_adapter`.

---@class DadbodUI.AdaptersModule
---@field Type DadbodUI.AdapterType
---@field register fun(spec: DadbodUI.Adapter): DadbodUI.Adapter
---@field unregister fun(name: string): boolean
---@field get fun(scheme: string|nil): DadbodUI.Adapter|nil
---@field canonical fun(scheme: string|nil): string|nil
---@field names fun(capability?: string): string[]

---@type DadbodUI.AdaptersModule
---@diagnostic disable-next-line: missing-fields
local M = {}

--- The built-in adapters as a static enum: each value is the canonical name
--- (also the key), so `adapters.Type.postgres` can replace the bare 'postgres'
--- string literal anywhere a canonical adapter name is expected. Custom
--- adapters registered at runtime are intentionally NOT in here -- the enum is
--- the closed set of names this plugin ships and tests against; `names()`
--- remains the open, runtime enumeration.
---@enum DadbodUI.AdapterType
M.Type = {
  postgres = 'postgres',
  mysql = 'mysql',
  mariadb = 'mariadb',
  sqlite = 'sqlite',
  sqlserver = 'sqlserver',
  oracle = 'oracle',
  bigquery = 'bigquery',
  clickhouse = 'clickhouse',
  mongodb = 'mongodb',
}

---@private
---@type table<string, DadbodUI.Adapter>  every scheme name (canonical + aliases) -> spec
local by_scheme = {}

---@private
---@type table<string, DadbodUI.Adapter>  canonical name -> spec, for enumeration
local by_name = {}

--- Register an adapter under its canonical name and every alias. Re-registering
--- a name replaces it (an intentional override hook: a user spec can shadow a
--- built-in). Returns the spec for chaining/extension.
---@param spec DadbodUI.Adapter
---@return DadbodUI.Adapter
function M.register(spec)
  assert(type(spec) == 'table' and type(spec.name) == 'string' and spec.name ~= '', 'adapter spec needs a name')
  by_name[spec.name] = spec
  by_scheme[spec.name] = spec
  for _, alias in ipairs(spec.aliases or {}) do
    by_scheme[alias] = spec
  end
  return spec
end

--- Remove the adapter registered under canonical `name` (and its aliases).
--- Returns whether one was removed. The inverse of `register` -- lets a user
--- disable a built-in, and keeps registration reversible for tests.
---@param name string
---@return boolean
function M.unregister(name)
  local spec = by_name[name]
  if spec == nil then
    return false
  end
  by_name[name] = nil
  by_scheme[name] = nil
  for _, alias in ipairs(spec.aliases or {}) do
    if by_scheme[alias] == spec then
      by_scheme[alias] = nil
    end
  end
  return true
end

--- The adapter for a url scheme (canonical name or alias, case-insensitive),
--- or nil for a scheme we don't know.
---@param scheme string|nil
---@return DadbodUI.Adapter|nil
function M.get(scheme)
  if scheme == nil then
    return nil
  end
  return by_scheme[scheme] or by_scheme[scheme:lower()]
end

--- The canonical adapter name for a scheme, or nil when unknown.
---@param scheme string|nil
---@return string|nil
function M.canonical(scheme)
  local spec = M.get(scheme)
  return spec and spec.name or nil
end

--- The sorted canonical names of every registered adapter; with `capability`
--- (a spec field name, e.g. 'explain' or 'pagination'), only adapters carrying
--- that field. Drives "supported: ..." error messages and feature gates.
---@param capability? string
---@return string[]
function M.names(capability)
  local names = {}
  for name, spec in pairs(by_name) do
    if capability == nil or spec[capability] ~= nil then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

-- Built-in adapters, one file per database -- the enum IS the load list, so a
-- new built-in is one file plus one enum entry.
for _, name in ipairs(vim.tbl_values(M.Type)) do
  M.register(require('dadbod-ui.adapters.' .. name))
end

return M
