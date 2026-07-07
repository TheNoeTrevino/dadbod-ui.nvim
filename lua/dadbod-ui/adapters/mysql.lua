-- MySQL: introspection, table helpers, explain, pagination, export
--
-- MariaDB (`adapters/mariadb.lua`) derives from this spec: the wire behavior is
-- identical except its executing EXPLAIN form, so it reuses everything here and
-- overrides only `name`/`explain`.

---@private
local parse = require('dadbod-ui.schemas.parse')

---@private
local foreign_key_query = [[
SELECT referenced_table_name, referenced_column_name, referenced_table_schema
from information_schema.key_column_usage
where referenced_table_name is not null and column_name = '{col_name}' LIMIT 1]]

---@type DadbodUI.Adapter
return {
  name = 'mysql',

  -- A mysql url that names a database in its path has no schema browsing: the
  -- drawer lists that database's tables directly (see schemas.supports_schemes).
  db_path_lists_tables = true,

  ---@param _config? DadbodUI.Config
  ---@return DadbodUI.SchemaAdapter
  schema = function(_config)
    return {
      schemes_query = 'SELECT schema_name FROM information_schema.schemata',
      schemes_tables_query = 'SELECT table_schema, table_name FROM information_schema.tables',
      -- Routines come from `information_schema.ROUTINES` filtered to
      -- `ROUTINE_TYPE IN ('PROCEDURE','FUNCTION')`, with their DDL read via
      -- `SHOW CREATE PROCEDURE/FUNCTION`. System schemas are excluded so the tree
      -- isn't flooded with server internals.
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
      foreign_key_query = foreign_key_query,
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
  end,

  --- dadbod's raw `tables` output prepends a header / warning lines; drop them.
  ---@param raw string[]
  ---@return string[]
  normalize_tables = function(raw)
    return vim.tbl_filter(function(name)
      -- Anchored to the START of the name: an unanchored `Tables_in_` would also
      -- drop any real table whose name merely CONTAINS that substring.
      return not name:match('mysql: %[Warning%]') and not name:match('^Tables_in')
    end, raw)
  end,

  table_helpers = {
    List = 'SELECT * from {optional_schema}`{table}` LIMIT 200',
    Columns = 'DESCRIBE {optional_schema}`{table}`',
    Indexes = 'SHOW INDEXES FROM {optional_schema}`{table}`',
    ['Foreign Keys'] = "SELECT * FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS WHERE TABLE_SCHEMA = '{schema}' AND TABLE_NAME = '{table}' AND CONSTRAINT_TYPE = 'FOREIGN KEY'",
    ['Primary Keys'] = "SELECT * FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS WHERE TABLE_SCHEMA = '{schema}' AND TABLE_NAME = '{table}' AND CONSTRAINT_TYPE = 'PRIMARY KEY'",
  },

  explain = { plain = 'EXPLAIN {sql}', analyze = 'EXPLAIN ANALYZE {sql}' },

  pagination = 'limit_comma',

  export = {
    stdin = true,
    extract = { '--batch' },
    -- NB: `tsv` is NOT native. mysql `--batch` emits literal `\N` for NULL and
    -- backslash-escaped values; the Lua TSV formatter (fed by the `--batch`
    -- extract) renders NULL -> empty consistently with postgres/sqlite, so TSV is
    -- uniformly the formatter across adapters. `--no-defaults` is deliberately NOT
    -- used as it would also drop ~/.my.cnf credentials.
    native = { html = { '--html' }, xml = { '--xml' } },
  },
}
