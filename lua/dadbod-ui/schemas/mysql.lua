-- MySQL / MariaDB schema/table introspection

---@private
local parse = require('dadbod-ui.schemas.parse')

---@private
local mysql_foreign_key_query = [[
SELECT referenced_table_name, referenced_column_name, referenced_table_schema
from information_schema.key_column_usage
where referenced_table_name is not null and column_name = '{col_name}' LIMIT 1]]

---@private
---@param config? DadbodUI.Config
---@return DadbodUI.SchemaAdapter
return function(config)
  return {
    schemes_query = 'SELECT schema_name FROM information_schema.schemata',
    schemes_tables_query = 'SELECT table_schema, table_name FROM information_schema.tables',
    -- DBeaver lists routines from `information_schema.ROUTINES` filtered to
    -- `ROUTINE_TYPE IN ('PROCEDURE','FUNCTION')` and reads their DDL with
    -- `SHOW CREATE PROCEDURE/FUNCTION` (MySQLCatalog.java / MySQLProcedure.java).
    -- System schemas are excluded so the tree isn't flooded with server internals.
    procedures_query = 'SELECT routine_schema, routine_name, LOWER(routine_type) FROM information_schema.routines '
      .. "WHERE routine_type IN ('PROCEDURE', 'FUNCTION') "
      .. "AND routine_schema NOT IN ('sys', 'mysql', 'information_schema', 'performance_schema') "
      .. 'ORDER BY routine_schema, routine_name',
    -- The tables-only path (a mysql url naming a database in its path -- see
    -- `supports_schemes`) has no schema browsing, so its Procedures node must be
    -- scoped to the connected database only: the global `procedures_query` above
    -- lists routines from EVERY schema on the server, which would otherwise all
    -- flatten into this one db's Procedures node.
    tables_procedures_query = 'SELECT routine_schema, routine_name, LOWER(routine_type) FROM information_schema.routines '
      .. "WHERE routine_type IN ('PROCEDURE', 'FUNCTION') AND routine_schema = DATABASE() "
      .. 'ORDER BY routine_name',
    ---@param schema string
    ---@param name string
    ---@param kind string
    ---@return string
    routine_definition = function(schema, name, kind)
      return string.format(
        'SHOW CREATE %s `%s`.`%s`',
        parse.routine_verb(kind),
        parse.my_backtick(schema),
        parse.my_backtick(name)
      )
    end,
    foreign_key_query = mysql_foreign_key_query,
    select_foreign_key_query = 'select * from %s.%s where %s = %s',
    cell_line_number = 3,
    cell_line_pattern = '^+-\\++-\\+',
    layout_flag = '\\G',
    requires_stdin = true,
    parse_results = function(results, min_len)
      return parse.results_parser(parse.vslice(results, 1), '\\t', min_len)
    end,
    default_scheme = '',
    quote = 0,
    filetype = 'mysql',
  }
end
