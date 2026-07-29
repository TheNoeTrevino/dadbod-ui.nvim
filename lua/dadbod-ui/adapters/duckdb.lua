-- DuckDB: postgres-flavored introspection over the sqlite-shaped CLI.
-- Introspection SQL follows postgres (information_schema, double-quoted
-- identifiers); the CLI is a sqlite3-shell derivative, so output framing and
-- export follow sqlite. No `procedures_query`: DuckDB has macros, not stored
-- procedures in the PG/MSSQL sense (#102), so the drawer omits that section.

local parse = require('dadbod-ui.schemas.parse')

-- `information_schema.schemata` also lists the system/temp catalogs (each with
-- their own `main`), so both queries scope to `current_database()`. ATTACH'd
-- catalogs are therefore not browsed -- documented known gap.
local schemes_query = [[
SELECT schema_name FROM information_schema.schemata
WHERE catalog_name = current_database()
  AND schema_name NOT IN ('information_schema', 'pg_catalog')
ORDER BY schema_name]]

local tables_query = [[
SELECT table_schema, table_name FROM information_schema.tables
WHERE table_catalog = current_database()
  AND table_schema NOT IN ('information_schema', 'pg_catalog')
ORDER BY table_schema, table_name]]

-- duckdb_constraints() stores FK columns as LISTs; [1] extracts the
-- single-column case, list_contains matches composite keys on any member.
local foreign_key_query = [[
SELECT referenced_table AS foreign_table_name,
       referenced_column_names[1] AS foreign_column_name,
       schema_name AS foreign_table_schema
FROM duckdb_constraints()
WHERE constraint_type = 'FOREIGN KEY'
  AND list_contains(constraint_column_names, '{col_name}')
LIMIT 1]]

---@type DadbodUI.Adapter
return {
  name = 'duckdb',
  schema = function(_config)
    return {
      -- Appended AFTER dadbod's interactive `-column -header`; the CLI is
      -- last-flag-wins, so introspection gets pipe-separated headerless rows
      -- (psql `-A -t` style) parsed with the postgres pipe parser.
      -- `-readonly` because DuckDB holds an exclusive file lock per read-write
      -- process: introspection fans out concurrent CLI calls (run_many), and
      -- only read-only opens may share the file.
      args = { '-readonly', '-list', '-noheader' },
      schemes_query = schemes_query,
      schemes_tables_query = tables_query,
      foreign_key_query = foreign_key_query,
      select_foreign_key_query = 'select * from "%s"."%s" where "%s" = %s',
      -- dbout buffers come from dadbod's `-column -header`, i.e. sqlite
      -- framing: header line, then a dash underline.
      cell_line_number = 2,
      cell_line_pattern = '^-\\+\\( \\+-\\+\\)*\\s*$',
      parse_results = function(results, min_len)
        local nonempty = vim.tbl_filter(function(row)
          return row ~= ''
        end, results)
        return parse.results_parser(nonempty, '|', min_len)
      end,
      default_scheme = 'main',
      quote = true,
    }
  end,
  table_helpers = {
    List = 'select * from {optional_schema}"{table}" LIMIT 200',
    Columns = "SELECT * FROM information_schema.columns WHERE table_name = '{table}' AND table_schema = '{schema}'",
    Indexes = "SELECT * FROM duckdb_indexes() WHERE table_name = '{table}' AND schema_name = '{schema}'",
    ['Foreign Keys'] = "SELECT * FROM duckdb_constraints() WHERE constraint_type = 'FOREIGN KEY' AND table_name = '{table}' AND schema_name = '{schema}'",
    References = "SELECT * FROM duckdb_constraints() WHERE constraint_type = 'FOREIGN KEY' AND referenced_table = '{table}' AND schema_name = '{schema}'",
    ['Primary Keys'] = "SELECT * FROM duckdb_constraints() WHERE constraint_type = 'PRIMARY KEY' AND table_name = '{table}' AND schema_name = '{schema}'",
  },
  explain = {
    plain = 'EXPLAIN {sql}',
    analyze = 'EXPLAIN ANALYZE {sql}',
    json = 'EXPLAIN (FORMAT JSON) {sql}',
    -- ANALYZE executes the statement, so the JSON form runs inside a
    -- rolled-back transaction (postgres convention) -- an analyzed DML
    -- statement must never commit its effects.
    json_analyze = 'BEGIN; EXPLAIN (ANALYZE, FORMAT JSON) {sql}; ROLLBACK;',
    -- The shell prints EXPLAIN results raw in every output mode, so the only
    -- flag needed is `-no-init` (a ~/.duckdbrc must not change modes or
    -- inject output). The box-art `Physical Plan` banner the shell prints
    -- before the plain JSON is stripped by the parser's `clean`.
    json_args = { '-no-init' },
    parser = 'dadbod-ui.explain.parsers.duckdb',
  },
  pagination = 'limit_offset',
  statements = {},
  export = {
    -- stdin like sqlite: the CLI treats a positional SQL string starting with
    -- `-` as an option. `-no-init` skips ~/.duckdbrc; `-nullvalue ''` makes
    -- CSV NULLs empty like the other adapters (duckdb defaults to `NULL`).
    stdin = true,
    extract = { '-no-init', '-nullvalue', '', '-csv' },
    native = {
      csv = { '-no-init', '-nullvalue', '', '-csv' },
      json = { '-no-init', '-json' },
    },
  },
}
