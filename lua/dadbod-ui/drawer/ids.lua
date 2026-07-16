-- Stable node ids for the drawer's expand map
--
-- Every togglable drawer node is identified by a stable path string, keyed off
-- domain identity (key_name / group / schema / table names) so the id survives
-- re-renders, re-introspection and drawer close/reopen. The drawer's `expand`
-- map (view state) is keyed by these ids -- expand/collapse state never lives
-- in the connection entries (domain data).

---@class DadbodUI.DrawerIds
local M = {}

--- The top-level `Query results` section.
M.DBOUT = 'dbout'

---@param name string
---@return string
function M.group(name)
  return 'group/' .. name
end

---@param key_name string
---@return string
function M.db(key_name)
  return 'db/' .. key_name
end

--- A section header under a connection ('buffers' | 'saved_queries' |
--- 'schemas' | 'tables' | 'routines').
---@param key_name string
---@param section string
---@return string
function M.section(key_name, section)
  return 'db/' .. key_name .. '/' .. section
end

---@param key_name string
---@param schema string
---@return string
function M.schema(key_name, schema)
  return M.section(key_name, 'schemas') .. '/' .. schema
end

--- A table node (`schema` is '' for non-schema adapters).
---@param key_name string
---@param schema string
---@param table_name string
---@return string
function M.table(key_name, schema, table_name)
  return M.section(key_name, 'tables') .. '/' .. schema .. '/' .. table_name
end

--- A per-schema routine bucket under the Procedures section.
---@param key_name string
---@param schema string
---@return string
function M.routine_schema(key_name, schema)
  return M.section(key_name, 'routines') .. '/' .. schema
end

--- One routine leaf (`schema` is '' for non-schema adapters). Togglable only for
--- adapters exposing "Script As"; the id is stable either way.
---@param key_name string
---@param schema string
---@param name string
---@return string
function M.routine(key_name, schema, name)
  return M.section(key_name, 'routines') .. '/' .. schema .. '/' .. name
end

--- The "Script As" node under a routine (SSMS-style DDL scripting submenu).
---@param key_name string
---@param schema string
---@param name string
---@return string
function M.routine_script_as(key_name, schema, name)
  return M.routine(key_name, schema, name) .. '/script_as'
end

return M
