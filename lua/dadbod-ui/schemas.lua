---@mod dadbod-ui.schemas  Per-adapter schema/table introspection (SQL + parsers)
---
--- Faithful port of vim-dadbod-ui's `autoload/db_ui/schemas.vim`. Each supported
--- adapter carries the SQL that lists its schemas and its (schema, table) pairs,
--- plus a `parse_results` function that turns the raw command output into either
--- a list of names (`min_len == 1`) or a list of `{ schema, table }` rows
--- (`min_len == 2`). The queries and the slicing/splitting rules are ported
--- verbatim -- they encode each CLI's exact output framing (header rows, footer
--- counts, column delimiters) and must not be paraphrased.
---
--- We diverge from the original in *execution only*: instead of dadbod's blocking
--- `db#systemlist`, the drawer builds a `DadbodUI.CommandSpec` via `command_spec`
--- and runs schema + table listing concurrently through `bridge.run_many`, so a
--- large database never freezes the UI on expand. The command construction still
--- goes through dadbod (via `bridge.command`) so the per-adapter argv stays
--- correct.

local bridge = require('dadbod-ui.bridge')

local M = {}

-- Result parsing -------------------------------------------------------------

-- Mimic Vim's list slice `list[from:to]`: 0-based, both bounds inclusive,
-- negative indices count from the end. `to` defaults to the last element (the
-- `list[from:]` form). Operates on a Lua 1-based array.
---@param list any[]
---@param from integer
---@param to? integer
---@return any[]
local function vslice(list, from, to)
  local n = #list
  to = to or -1
  if from < 0 then
    from = n + from
  end
  if to < 0 then
    to = n + to
  end
  local out = {}
  for i = from, to do
    if i >= 0 and i < n then
      out[#out + 1] = list[i + 1]
    end
  end
  return out
end

---@param value string
---@return boolean
local function blank(value)
  return vim.trim(value) == ''
end

-- Escape a value for embedding inside a single-quoted SQL string literal
-- (postgres / sqlserver / oracle): double every single quote. Used by the
-- routine-definition queries so a routine whose name/schema contains a quote is
-- looked up correctly instead of terminating the literal early.
---@param s string
---@return string
local function sql_squote(s)
  return (s:gsub("'", "''"))
end

-- Escape a value for embedding inside a backtick-quoted MySQL identifier: double
-- every backtick. Used by `SHOW CREATE PROCEDURE/FUNCTION`.
---@param s string
---@return string
local function my_backtick(s)
  return (s:gsub('`', '``'))
end

-- Map a normalized routine kind ('procedure'|'function') to the SQL keyword used
-- by the `SHOW CREATE`/`GET_DDL`-style definition builders (mysql, oracle).
---@param kind string
---@return string
local function routine_verb(kind)
  return kind == 'function' and 'FUNCTION' or 'PROCEDURE'
end

-- Port of `s:results_parser`. `delimiter` is a Vim regex (split is done with
-- `vim.fn.split`, identical to the original). For `min_len == 1` the rows are
-- returned untouched (sans blanks); otherwise each row is split into fields and
-- only the rows of the expected width are kept -- when `min_len == 0` that width
-- is the widest row seen.
---@param results string[]
---@param delimiter string
---@param min_len integer
---@return any[]
local function results_parser(results, delimiter, min_len)
  if min_len == 1 then
    return vim.tbl_filter(function(row)
      return not blank(row)
    end, results)
  end

  local mapped = vim.tbl_map(function(row)
    return vim.tbl_filter(function(field)
      return not blank(field)
    end, vim.fn.split(row, delimiter))
  end, results)

  if min_len > 1 then
    return vim.tbl_filter(function(fields)
      return #fields == min_len
    end, mapped)
  end

  local max_len = 0
  for _, fields in ipairs(mapped) do
    max_len = math.max(max_len, #fields)
  end
  return vim.tbl_filter(function(fields)
    return #fields == max_len
  end, mapped)
end
M.results_parser = results_parser

-- Adapter definitions --------------------------------------------------------

local postgres_list_schema_query = [[
SELECT nspname as schema_name
FROM pg_catalog.pg_namespace
WHERE nspname !~ '^pg_temp_'
  and pg_catalog.has_schema_privilege(current_user, nspname, 'USAGE')
order by nspname]]

local postgres_tables_query = 'SELECT table_schema, table_name FROM information_schema.tables ;'
local postgres_tables_and_views_query =
  'SELECT table_schema, table_name FROM information_schema.tables UNION ALL select schemaname, matviewname from pg_matviews;'

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
    sql_squote(schema),
    sql_squote(name)
  )
end

local postgres_foreign_key_query = [[
SELECT ccu.table_name AS foreign_table_name, ccu.column_name AS foreign_column_name, ccu.table_schema as foreign_table_schema
FROM
    information_schema.table_constraints AS tc
    JOIN information_schema.key_column_usage AS kcu
      ON tc.constraint_name = kcu.constraint_name
    JOIN information_schema.constraint_column_usage AS ccu
      ON ccu.constraint_name = tc.constraint_name
WHERE constraint_type = 'FOREIGN KEY' and kcu.column_name = '{col_name}' LIMIT 1]]

---@param config? DadbodUI.Config
---@return DadbodUI.SchemaAdapter
local function postgresql(config)
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
      return results_parser(vslice(nonempty, 1, -2), '|', min_len)
    end,
    default_scheme = 'public',
    quote = 1,
  }
end

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

---@return DadbodUI.SchemaAdapter
local function sqlserver()
  return {
    args = { '-h-1', '-W', '-s', '|', '-Q' },
    schemes_query = 'SELECT schema_name FROM INFORMATION_SCHEMA.SCHEMATA',
    schemes_tables_query = 'SELECT table_schema, table_name FROM INFORMATION_SCHEMA.TABLES',
    -- DBeaver reads sqlserver routines from `sys.all_objects` (type IN P/FN/TF/…)
    -- and their source via `OBJECT_DEFINITION(object_id)` / `sys.sql_modules`
    -- (SQLServerSchema.java / SQLServerUtils.extractSource). We use the portable
    -- INFORMATION_SCHEMA.ROUTINES for the listing (consistent with the other
    -- sqlserver queries here) and `OBJECT_DEFINITION(OBJECT_ID(...))` for the DDL.
    procedures_query = 'SELECT routine_schema, routine_name, LOWER(routine_type) FROM INFORMATION_SCHEMA.ROUTINES '
      .. "WHERE routine_type IN ('PROCEDURE', 'FUNCTION') ORDER BY routine_schema, routine_name",
    ---@param schema string
    ---@param name string
    ---@param _kind string
    ---@return string
    routine_definition = function(schema, name, _kind)
      return string.format("SELECT OBJECT_DEFINITION(OBJECT_ID('%s.%s'))", sql_squote(schema), sql_squote(name))
    end,
    foreign_key_query = sqlserver_foreign_key_query,
    select_foreign_key_query = 'select * from %s.%s where %s = %s',
    cell_line_number = 2,
    cell_line_pattern = '^-\\+.-\\+',
    parse_results = function(results, min_len)
      return results_parser(vslice(results, 0, -3), '|', min_len)
    end,
    quote = 0,
    default_scheme = 'dbo',
  }
end

local mysql_foreign_key_query = [[
SELECT referenced_table_name, referenced_column_name, referenced_table_schema
from information_schema.key_column_usage
where referenced_table_name is not null and column_name = '{col_name}' LIMIT 1]]

---@return DadbodUI.SchemaAdapter
local function mysql()
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
    ---@param schema string
    ---@param name string
    ---@param kind string
    ---@return string
    routine_definition = function(schema, name, kind)
      return string.format('SHOW CREATE %s `%s`.`%s`', routine_verb(kind), my_backtick(schema), my_backtick(name))
    end,
    foreign_key_query = mysql_foreign_key_query,
    select_foreign_key_query = 'select * from %s.%s where %s = %s',
    cell_line_number = 3,
    cell_line_pattern = '^+-\\++-\\+',
    layout_flag = '\\G',
    requires_stdin = true,
    parse_results = function(results, min_len)
      return results_parser(vslice(results, 1), '\\t', min_len)
    end,
    default_scheme = '',
    quote = 0,
    filetype = 'mysql',
  }
end

-- Oracle wraps every query with SQL*Plus formatting (`SET linesize ...`) joined
-- with `;\n`, ending in `;` -- the original builds this with `printf`, so the
-- query takes the place of the trailing `%s`.
local oracle_arg_lines = {
  'SET linesize 4000',
  'SET pagesize 4000',
  'COLUMN owner FORMAT a20',
  'COLUMN table_name FORMAT a25',
  'COLUMN column_name FORMAT a25',
}

---@param query string
---@return string
local function oracle_wrap(query)
  return table.concat(oracle_arg_lines, ';\n') .. ';\n' .. query .. ';'
end

---@param config? DadbodUI.Config
---@return DadbodUI.SchemaAdapter
local function oracle(config)
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

  -- Standalone procedures + functions from the data dictionary (DBeaver reads
  -- `ALL_OBJECTS` for the routine list and `DBMS_METADATA.GET_DDL` for the
  -- source). Packaged routines are intentionally out of scope here.
  local procedures_query = [[
SELECT /*csv*/ O.owner, O.object_name, LOWER(O.object_type)
 FROM all_objects O
 JOIN all_users U ON O.owner = U.username
 WHERE O.object_type IN ('PROCEDURE', 'FUNCTION')
 ]] .. common_condition .. [[

 ORDER BY O.owner, O.object_name]]

  local ora_bin = vim.g.dbext_default_ORA_bin or ''
  local csv = ora_bin == 'sql' or ora_bin == 'sqlcl'

  local function parse(results, min_len)
    local rows = vslice(results, 3)
    if csv then
      -- strip_quotes: join, drop double quotes, split on whitespace
      local joined = table.concat(rows, ' '):gsub('"', '')
      return results_parser(vim.fn.split(joined), ',', min_len)
    end
    return results_parser(rows, '\\s\\s\\+', min_len)
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
          routine_verb(kind),
          sql_squote(name),
          sql_squote(schema)
        )
      )
    end,
    foreign_key_query = oracle_wrap(foreign_key_query),
    select_foreign_key_query = oracle_wrap('SELECT /*csv*/ * FROM "%s"."%s" WHERE "%s" = %s'),
    cell_line_number = 1,
    cell_line_pattern = '^-\\+\\( \\+-\\+\\)*',
    has_virtual_results = true,
    parse_results = parse,
    parse_virtual_results = parse,
    filetype = 'plsql',
  }
end

---@return DadbodUI.SchemaAdapter
local function bigquery()
  local region = vim.g.db_adapter_bigquery_region or 'region-us'
  return {
    callable = 'filter',
    args = { '--format=csv', '--max_rows=100000' },
    schemes_query = string.format('SELECT schema_name FROM `%s`.INFORMATION_SCHEMA.SCHEMATA', region),
    schemes_tables_query = string.format('SELECT table_schema, table_name FROM `%s`.INFORMATION_SCHEMA.TABLES', region),
    parse_results = function(results, min_len)
      return results_parser(vslice(results, 1), ',', min_len)
    end,
    layout_flag = '\\x',
    requires_stdin = true,
  }
end

-- sqlite has no information_schema, so resolve a column's foreign table globally
-- via the `pragma_foreign_key_list` table-valued function joined over
-- `sqlite_master` -- this matches the `{col_name}`-only interface the other
-- adapters use. The third column is the literal `main` (sqlite's default
-- database) so the postgres-style schema-qualified select template works as-is
-- (`"main"."table"` is valid sqlite).
local sqlite_foreign_key_query = [[
SELECT fkl."table" AS foreign_table_name, fkl."to" AS foreign_column_name, 'main' AS foreign_table_schema
FROM sqlite_master m
JOIN pragma_foreign_key_list(m.name) fkl
WHERE m.type = 'table' AND fkl."from" = '{col_name}'
LIMIT 1]]

-- Divergence from the original: vim-dadbod-ui has no sqlite schema entry at all,
-- so it supports neither the foreign-key jump nor cell/header navigation in
-- sqlite result buffers. We add the dbout-only fields below (deliberately NO
-- `schemes_query`, so sqlite stays the tables-only drawer path). dadbod renders
-- sqlite results with `-column -header`, i.e. space-aligned columns under a
-- `---` underline -- hence cell_line_number 2 and the dash-rule pattern, and a
-- parser that drops the header + underline and splits on the column gaps.
---@return DadbodUI.SchemaAdapter
local function sqlite()
  return {
    foreign_key_query = sqlite_foreign_key_query,
    select_foreign_key_query = 'select * from "%s"."%s" where "%s" = %s',
    cell_line_number = 2,
    cell_line_pattern = '^-\\+\\( \\+-\\+\\)*\\s*$',
    parse_results = function(results, min_len)
      return results_parser(vslice(results, 2), '\\s\\s\\+', min_len)
    end,
  }
end

---@return DadbodUI.SchemaAdapter
local function clickhouse()
  return {
    args = { '-q' },
    schemes_query = 'SELECT name as schema_name FROM system.databases ORDER BY name',
    schemes_tables_query = 'SELECT database AS table_schema, name AS table_name FROM system.tables ORDER BY table_name',
    cell_line_number = 1,
    cell_line_pattern = '^.*$',
    parse_results = function(results, min_len)
      return results_parser(results, '\\t', min_len)
    end,
    default_scheme = '',
    quote = 1,
  }
end

-- scheme -> builder. Postgres aliases share one builder. sqlite's entry carries
-- ONLY dbout-navigation metadata (no schemes_query), so it keeps the tables-only
-- drawer path while still supporting the foreign-key jump + cell/header nav --
-- our improvement over the original, which had no sqlite entry at all.
local builders = {
  postgres = postgresql,
  postgresql = postgresql,
  sqlserver = sqlserver,
  mysql = mysql,
  mariadb = mysql,
  oracle = oracle,
  bigquery = bigquery,
  sqlite = sqlite,
  sqlite3 = sqlite,
  clickhouse = clickhouse,
}

--- The metadata for `scheme`, or an empty table for a scheme we don't know.
--- Note this is NOT the same as "no schema support": sqlite returns a non-empty
--- table carrying only dbout-navigation fields (no `schemes_query`), so it has
--- metadata without schema support. `config` tunes the queries that depend on
--- options (`use_postgres_views`, `is_oracle_legacy`).
---@param scheme string  raw url scheme
---@param config? DadbodUI.Config
---@return DadbodUI.SchemaAdapter
function M.get(scheme, config)
  local builder = builders[scheme]
  if builder == nil then
    return {}
  end
  return builder(config)
end

--- Whether the adapter exposes schemas for this url. Mirrors the original:
--- schema support requires a `schemes_query`, and MySQL/MariaDB urls that name a
--- database in the path list tables directly instead.
---@param scheme_info DadbodUI.SchemaAdapter
---@param parsed_url DadbodUI.ParsedUrl
---@return boolean
function M.supports_schemes(scheme_info, parsed_url)
  if scheme_info == nil or scheme_info.schemes_query == nil or scheme_info.schemes_query == '' then
    return false
  end
  local scheme_name = (parsed_url.scheme or ''):lower()
  if (scheme_name == 'mysql' or scheme_name == 'mariadb') and (parsed_url.path or '') ~= '/' then
    return false
  end
  return true
end

--- Build the command spec for running `query` against `conn` with this adapter.
--- Port of the original `s:format_query`: dadbod constructs the base argv for the
--- adapter's `callable` (interactive by default), the adapter's extra `args` are
--- appended, and the query is either fed on stdin (`requires_stdin`) or appended
--- as the final argument.
---@param conn string  resolved connection url
---@param scheme_info DadbodUI.SchemaAdapter
---@param query string
---@return DadbodUI.CommandSpec
function M.command_spec(conn, scheme_info, query)
  local callable = scheme_info.callable or 'interactive'
  local cmd = bridge.command(conn, callable)
  if scheme_info.args then
    vim.list_extend(cmd, scheme_info.args)
  end
  if scheme_info.requires_stdin then
    return { cmd = cmd, stdin = query }
  end
  cmd[#cmd + 1] = query
  return { cmd = cmd }
end

--- Run `query` against `conn` synchronously and return its output lines (trailing
--- CR stripped), mirroring the original `db_ui#schemas#query`. Blocks Neovim, so
--- it is reserved for the single small introspection lookup the dbout foreign-key
--- jump needs -- not for the drawer's bulk introspection, which fans out async via
--- `run_many`. Goes through the bridge (the engine boundary) for the actual call.
---@param conn string  resolved connection url
---@param scheme_info DadbodUI.SchemaAdapter
---@param query string
---@return string[]
function M.query(conn, scheme_info, query)
  local spec = M.command_spec(conn, scheme_info, query)
  local result = bridge.systemlist(spec.cmd, spec.stdin)
  return vim.tbl_map(function(line)
    return (line:gsub('\r$', ''))
  end, result)
end

--- Turn one `vim.system` result into the line list dadbod's `db#systemlist`
--- would have returned: empty on a non-zero exit, otherwise stdout split into
--- lines with trailing CR stripped and the single trailing blank line (from the
--- final newline) dropped. Only ONE trailing blank is dropped -- matching
--- systemlist exactly -- because adapters with a fixed-tail slice (e.g.
--- sqlserver's `[0:-3]`) are calibrated to that framing.
---@param result vim.SystemCompleted
---@return string[]
function M.result_lines(result)
  if result == nil or result.code ~= 0 then
    return {}
  end
  local lines = vim.split(result.stdout or '', '\n')
  for i, line in ipairs(lines) do
    lines[i] = (line:gsub('\r$', ''))
  end
  if #lines > 0 and lines[#lines] == '' then
    lines[#lines] = nil
  end
  return lines
end

--- Normalize the raw table list dadbod's `tables` adapter call returns for a
--- non-schema adapter. Port of the per-adapter cleanup the original does inline
--- in `populate_tables`: sqlite lists tables as space-separated strings (split
--- and sort), mysql prepends a header / warning lines (filter them out).
---@param scheme string
---@param raw string[]
---@return string[]
function M.normalize_table_list(scheme, raw)
  local lower = scheme:lower()
  if lower:match('^sqlite') then
    local flattened = vim
      .iter(raw)
      :map(function(chunk)
        return vim.split(chunk, '%s+', { trimempty = true })
      end)
      :flatten()
      :map(vim.trim)
      :totable()
    table.sort(flattened)
    return flattened
  end
  if lower:match('^mysql') then
    return vim.tbl_filter(function(name)
      return not name:match('mysql: %[Warning%]') and not name:match('Tables_in_')
    end, raw)
  end
  return raw
end

return M
