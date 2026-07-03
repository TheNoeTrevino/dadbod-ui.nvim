-- SQL Server schema/table introspection

---@private
local parse = require('dadbod-ui.schemas.parse')

---@private
local sqlserver_foreign_key_query = [[
SELECT TOP 1 c2.table_name as foreign_table_name, kcu2.column_name as foreign_column_name, kcu2.table_schema as foreign_table_schema
from   information_schema.table_constraints c
       inner join information_schema.key_column_usage kcu
         on c.constraint_schema = kcu.constraint_schema and c.constraint_name = kcu.constraint_name
       inner join information_schema.referential_constraints rc
         on c.constraint_schema = rc.constraint_schema and c.constraint_name = rc.constraint_name
       inner join information_schema.table_constraints c2
         on rc.unique_constraint_schema = c2.constraint_schema and rc.unique_constraint_name = c2.constraint_name
       inner join information_schema.key_column_usage kcu2
         on c2.constraint_schema = kcu2.constraint_schema and c2.constraint_name = kcu2.constraint_name and kcu.ordinal_position = kcu2.ordinal_position
where  c.constraint_type = 'FOREIGN KEY'
and kcu.column_name = '{col_name}']]

---@private
---@param config? DadbodUI.Config
---@return DadbodUI.SchemaAdapter
return function(config)
  return {
    args = { '-h-1', '-W', '-s', '|', '-Q' },
    schemes_query = 'SELECT schema_name FROM INFORMATION_SCHEMA.SCHEMATA',
    schemes_tables_query = 'SELECT table_schema, table_name FROM INFORMATION_SCHEMA.TABLES',
    -- sqlserver routines live in `sys.all_objects` (type IN P/FN/TF/…) with their
    -- source in `OBJECT_DEFINITION(object_id)` / `sys.sql_modules`. We use the
    -- portable INFORMATION_SCHEMA.ROUTINES for the listing (consistent with the
    -- other sqlserver queries here) and `OBJECT_DEFINITION(OBJECT_ID(...))` for the
    -- DDL.
    procedures_query = 'SELECT routine_schema, routine_name, LOWER(routine_type) FROM INFORMATION_SCHEMA.ROUTINES '
      .. "WHERE routine_type IN ('PROCEDURE', 'FUNCTION') ORDER BY routine_schema, routine_name",
    ---@param schema string
    ---@param name string
    ---@param _kind string
    ---@return string
    routine_definition = function(schema, name, _kind)
      -- Bracket-quote each part (`[schema].[name]`) so a schema/routine name
      -- containing a space or a dot still resolves -- unquoted, `OBJECT_ID`
      -- would parse the dot as the schema separator and return NULL, silently
      -- yielding an empty definition. `sql_squote` then escapes the whole
      -- bracket-quoted literal for the outer single-quoted string.
      local qualified = string.format('[%s].[%s]', parse.sql_bracket(schema), parse.sql_bracket(name))
      return string.format("SELECT OBJECT_DEFINITION(OBJECT_ID('%s'))", parse.sql_squote(qualified))
    end,
    foreign_key_query = sqlserver_foreign_key_query,
    select_foreign_key_query = 'select * from %s.%s where %s = %s',
    cell_line_number = 2,
    cell_line_pattern = '^-\\+.-\\+',
    parse_results = function(results, min_len)
      return parse.results_parser(parse.vslice(results, 0, -3), '|', min_len)
    end,
    quote = 0,
    default_scheme = 'dbo',
  }
end
