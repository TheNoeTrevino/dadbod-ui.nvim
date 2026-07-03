-- Oracle schema/table introspection

---@private
local parse = require('dadbod-ui.schemas.parse')

---@private
-- Oracle wraps every query with SQL*Plus formatting (`SET linesize ...`) joined
-- with `;\n`, ending in `;`; the query is appended after the formatting lines.
local oracle_arg_lines = {
  'SET linesize 4000',
  'SET pagesize 4000',
  'COLUMN owner FORMAT a20',
  'COLUMN table_name FORMAT a25',
  'COLUMN column_name FORMAT a25',
}

---@private
---@param query string
---@return string
local function oracle_wrap(query)
  return table.concat(oracle_arg_lines, ';\n') .. ';\n' .. query .. ';'
end

---@private
---@param config? DadbodUI.Config
---@return DadbodUI.SchemaAdapter
return function(config)
  local legacy = config ~= nil and config.is_oracle_legacy
  local common_condition = legacy and '' or "AND U.common = 'NO'"

  local foreign_key_query = [[
SELECT /*csv*/ DISTINCT RFRD.table_name, RFRD.column_name, RFRD.owner
 FROM all_cons_columns RFRD
 JOIN all_constraints CON ON RFRD.constraint_name = CON.r_constraint_name
 JOIN all_cons_columns RFRING ON CON.constraint_name = RFRING.constraint_name
 JOIN all_users U ON CON.owner = U.username
 WHERE CON.constraint_type = 'R'
 ]] .. common_condition .. [[

 AND RFRING.column_name = '{col_name}']]

  local schemes_query = [[
SELECT /*csv*/ username
 FROM all_users U
 WHERE 1 = 1
 ]] .. common_condition .. [[

 ORDER BY username]]

  local schemes_tables_query = [[
SELECT /*csv*/ T.owner, T.table_name
 FROM (
 SELECT owner, table_name
 FROM all_tables
 UNION SELECT owner, view_name AS "table_name"
 FROM all_views
 ) T
 JOIN all_users U ON T.owner = U.username
 WHERE 1 = 1
 ]] .. common_condition .. [[

 ORDER BY T.table_name]]

  -- Standalone procedures + functions from the data dictionary: `ALL_OBJECTS`
  -- for the routine list and `DBMS_METADATA.GET_DDL` for the source. Packaged
  -- routines are intentionally out of scope here.
  local procedures_query = [[
SELECT /*csv*/ O.owner, O.object_name, LOWER(O.object_type)
 FROM all_objects O
 JOIN all_users U ON O.owner = U.username
 WHERE O.object_type IN ('PROCEDURE', 'FUNCTION')
 ]] .. common_condition .. [[

 ORDER BY O.owner, O.object_name]]

  local ora_bin = vim.g.dbext_default_ORA_bin or ''
  local csv = ora_bin == 'sql' or ora_bin == 'sqlcl'

  local function parse_output(results, min_len)
    local rows = parse.vslice(results, 3)
    if csv then
      -- strip_quotes: join, drop double quotes, split on whitespace
      local joined = table.concat(rows, ' '):gsub('"', '')
      return parse.results_parser(vim.fn.split(joined), ',', min_len)
    end
    return parse.results_parser(rows, '\\s\\s\\+', min_len)
  end

  return {
    callable = 'filter',
    default_scheme = '',
    requires_stdin = true,
    quote = 1,
    schemes_query = oracle_wrap(schemes_query),
    schemes_tables_query = oracle_wrap(schemes_tables_query),
    procedures_query = oracle_wrap(procedures_query),
    ---@param schema string
    ---@param name string
    ---@param kind string
    ---@return string
    routine_definition = function(schema, name, kind)
      return oracle_wrap(
        string.format(
          "SELECT DBMS_METADATA.GET_DDL('%s', '%s', '%s') FROM DUAL",
          parse.routine_verb(kind),
          parse.sql_squote(name),
          parse.sql_squote(schema)
        )
      )
    end,
    foreign_key_query = oracle_wrap(foreign_key_query),
    select_foreign_key_query = oracle_wrap('SELECT /*csv*/ * FROM "%s"."%s" WHERE "%s" = %s'),
    cell_line_number = 1,
    cell_line_pattern = '^-\\+\\( \\+-\\+\\)*',
    has_virtual_results = true,
    parse_results = parse_output,
    parse_virtual_results = parse_output,
    filetype = 'plsql',
  }
end
