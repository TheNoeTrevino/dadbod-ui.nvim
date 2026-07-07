-- SQL Server: introspection and table helpers
--
-- No explain (SHOWPLAN is a session-batch setting, not a query wrap), no
-- pagination (TOP injection needs clause-level rewriting), no export (not a v1
-- export adapter).

---@private
local parse = require('dadbod-ui.schemas.parse')

---@private
local foreign_key_query = [[
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
local column_summary_query = table.concat({
  "select c.column_name + ' (' + ",
  "    isnull(( select 'PK, ' from information_schema.table_constraints as k join information_schema.key_column_usage as kcu on k.constraint_name = kcu.constraint_name where constraint_type='PRIMARY KEY' and k.table_name = c.table_name and kcu.column_name = c.column_name), '') + ",
  "    isnull(( select 'FK, ' from information_schema.table_constraints as k join information_schema.key_column_usage as kcu on k.constraint_name = kcu.constraint_name where constraint_type='FOREIGN KEY' and k.table_name = c.table_name and kcu.column_name = c.column_name), '') + ",
  "    data_type + coalesce('(' + rtrim(cast(character_maximum_length as varchar)) + ')','(' + rtrim(cast(numeric_precision as varchar)) + ',' + rtrim(cast(numeric_scale as varchar)) + ')','(' + rtrim(cast(datetime_precision as varchar)) + ')','') + ', ' + ",
  "    case when is_nullable = 'YES' then 'null' else 'not null' end + ')' as Columns ",
  " from information_schema.columns c where c.table_name='{table}' and c.TABLE_SCHEMA = '{schema}'",
}, '\n')

---@private
local foreign_keys_helper_query = table.concat({
  'SELECT c.constraint_name  ',
  '    ,kcu.column_name as column_name  ',
  '    ,c2.table_name as foreign_table_name  ',
  '    ,kcu2.column_name as foreign_column_name ',
  ' from   information_schema.table_constraints c  ',
  '        inner join information_schema.key_column_usage kcu  ',
  '          on c.constraint_schema = kcu.constraint_schema  ',
  '             and c.constraint_name = kcu.constraint_name  ',
  '        inner join information_schema.referential_constraints rc  ',
  '          on c.constraint_schema = rc.constraint_schema  ',
  '             and c.constraint_name = rc.constraint_name  ',
  '        inner join information_schema.table_constraints c2  ',
  '          on rc.unique_constraint_schema = c2.constraint_schema  ',
  '             and rc.unique_constraint_name = c2.constraint_name  ',
  '        inner join information_schema.key_column_usage kcu2  ',
  '          on c2.constraint_schema = kcu2.constraint_schema  ',
  '             and c2.constraint_name = kcu2.constraint_name  ',
  '             and kcu.ordinal_position = kcu2.ordinal_position  ',
  ' where  c.constraint_type = ' .. "'FOREIGN KEY'  ",
  " and c.TABLE_NAME = '{table}' and c.TABLE_SCHEMA = '{schema}'",
}, '\n')

---@private
local references_query = table.concat({
  ' select kcu1.constraint_name as constraint_name  ',
  '     ,kcu1.table_name as foreign_table_name   ',
  '     ,kcu1.column_name as foreign_column_name  ',
  '     ,kcu2.column_name as column_name  ',
  ' from information_schema.referential_constraints as rc  ',
  ' inner join information_schema.key_column_usage as kcu1  ',
  '     on kcu1.constraint_catalog = rc.constraint_catalog   ',
  '     and kcu1.constraint_schema = rc.constraint_schema  ',
  '     and kcu1.constraint_name = rc.constraint_name  ',
  ' inner join information_schema.key_column_usage as kcu2  ',
  '     on kcu2.constraint_catalog = rc.unique_constraint_catalog   ',
  '     and kcu2.constraint_schema = rc.unique_constraint_schema  ',
  '     and kcu2.constraint_name = rc.unique_constraint_name  ',
  '     and kcu2.ordinal_position = kcu1.ordinal_position  ',
  " where kcu2.table_name='{table}' and kcu2.table_schema = '{schema}'",
}, '\n')

---@private
local primary_keys_query = table.concat({
  '  select tc.constraint_name, kcu.column_name ',
  '  from ',
  '      information_schema.table_constraints AS tc ',
  '      JOIN information_schema.key_column_usage AS kcu ',
  '        ON tc.constraint_name = kcu.constraint_name ',
  '      JOIN information_schema.constraint_column_usage AS ccu ',
  '        ON ccu.constraint_name = tc.constraint_name ',
  " where constraint_type = 'PRIMARY KEY' ",
  " and tc.table_name = '{table}' and tc.table_schema = '{schema}'",
}, '\n')

---@private
local constraints_query = table.concat({
  ' SELECT u.CONSTRAINT_NAME, c.CHECK_CLAUSE FROM INFORMATION_SCHEMA.CONSTRAINT_TABLE_USAGE u ',
  '     inner join INFORMATION_SCHEMA.CHECK_CONSTRAINTS c on u.CONSTRAINT_NAME = c.CONSTRAINT_NAME ',
  " where TABLE_NAME = '{table}' and u.TABLE_SCHEMA = '{schema}'",
}, '\n')

---@type DadbodUI.Adapter
return {
  name = 'sqlserver',

  ---@param _config? DadbodUI.Config
  ---@return DadbodUI.SchemaAdapter
  schema = function(_config)
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
      foreign_key_query = foreign_key_query,
      select_foreign_key_query = 'select * from %s.%s where %s = %s',
      cell_line_number = 2,
      cell_line_pattern = '^-\\+.-\\+',
      parse_results = function(results, min_len)
        return parse.results_parser(parse.vslice(results, 0, -3), '|', min_len)
      end,
      quote = 0,
      default_scheme = 'dbo',
    }
  end,

  table_helpers = {
    List = 'select top 200 * from {optional_schema}[{table}]',
    Columns = column_summary_query,
    Indexes = "exec sp_helpindex '{schema}.{table}'",
    ['Foreign Keys'] = foreign_keys_helper_query,
    References = references_query,
    ['Primary Keys'] = primary_keys_query,
    Constraints = constraints_query,
    Describe = "exec sp_help '{schema}.{table}'",
  },
}
