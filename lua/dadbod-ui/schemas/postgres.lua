---@mod dadbod-ui.schemas.postgres  Postgres schema/table introspection

---@private
local parse = require('dadbod-ui.schemas.parse')

---@private
local postgres_list_schema_query = [[
SELECT nspname as schema_name
FROM pg_catalog.pg_namespace
WHERE nspname !~ '^pg_temp_'
  and pg_catalog.has_schema_privilege(current_user, nspname, 'USAGE')
order by nspname]]

---@private
local postgres_tables_query = 'SELECT table_schema, table_name FROM information_schema.tables ;'
---@private
local postgres_tables_and_views_query =
  'SELECT table_schema, table_name FROM information_schema.tables UNION ALL select schemaname, matviewname from pg_matviews;'

---@private
-- Stored procedures + functions. DBeaver lists routines from `pg_catalog.pg_proc`
-- keyed by `prokind` (`p` procedure, `f` function, `a` aggregate, `w` window) and
-- reads their DDL with `pg_get_functiondef(oid)` (see PostgreSchema.java /
-- PostgreProcedure.java). We list only plain procedures + functions (`prokind IN
-- ('f','p')`); aggregate/window entries are excluded because `pg_get_functiondef`
-- raises on them. `prokind` is postgres 11+; earlier servers used `proisagg` and
-- had no procedures, which we don't target.
local postgres_procedures_query = [[
SELECT n.nspname AS routine_schema, p.proname AS routine_name,
       CASE p.prokind WHEN 'p' THEN 'procedure' ELSE 'function' END AS routine_type
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
WHERE p.prokind IN ('f', 'p')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname !~ '^pg_'
ORDER BY n.nspname, p.proname]]

---@private
-- The DDL for one routine: every overload of (schema, name) via
-- `pg_get_functiondef`. Matching on name + namespace (rather than casting to
-- `regproc`) sidesteps the overload-ambiguity error and prints each overload's
-- source. Quotes in the identifiers are doubled so they stay inside the literal.
---@param schema string
---@param name string
---@param _kind string
---@return string
local function postgres_routine_definition(schema, name, _kind)
  return string.format(
    [[SELECT pg_get_functiondef(p.oid)
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = '%s' AND p.proname = '%s';]],
    parse.sql_squote(schema),
    parse.sql_squote(name)
  )
end

---@private
local postgres_foreign_key_query = [[
SELECT ccu.table_name AS foreign_table_name, ccu.column_name AS foreign_column_name, ccu.table_schema as foreign_table_schema
FROM
    information_schema.table_constraints AS tc
    JOIN information_schema.key_column_usage AS kcu
      ON tc.constraint_name = kcu.constraint_name
    JOIN information_schema.constraint_column_usage AS ccu
      ON ccu.constraint_name = tc.constraint_name
WHERE constraint_type = 'FOREIGN KEY' and kcu.column_name = '{col_name}' LIMIT 1]]

---@private
---@param config? DadbodUI.Config
---@return DadbodUI.SchemaAdapter
return function(config)
  local use_views = config == nil or config.use_postgres_views
  return {
    args = { '-A', '-c' },
    schemes_query = postgres_list_schema_query,
    schemes_tables_query = use_views and postgres_tables_and_views_query or postgres_tables_query,
    procedures_query = postgres_procedures_query,
    routine_definition = postgres_routine_definition,
    foreign_key_query = postgres_foreign_key_query,
    select_foreign_key_query = 'select * from "%s"."%s" where "%s" = %s',
    cell_line_number = 2,
    cell_line_pattern = '^-\\++-\\+',
    layout_flag = '\\x',
    parse_results = function(results, min_len)
      local nonempty = vim.tbl_filter(function(row)
        return row ~= ''
      end, results)
      return parse.results_parser(parse.vslice(nonempty, 1, -2), '|', min_len)
    end,
    default_scheme = 'public',
    quote = 1,
  }
end
