-- Postgres: introspection, table helpers, explain, pagination, export

---@private
local parse = require('dadbod-ui.schemas.parse')

---@private
local list_schema_query = [[
SELECT nspname as schema_name
FROM pg_catalog.pg_namespace
WHERE nspname !~ '^pg_temp_'
  and pg_catalog.has_schema_privilege(current_user, nspname, 'USAGE')
order by nspname]]

---@private
local tables_query = 'SELECT table_schema, table_name FROM information_schema.tables ;'
---@private
local tables_and_views_query =
  'SELECT table_schema, table_name FROM information_schema.tables UNION ALL select schemaname, matviewname from pg_matviews;'

---@private
-- Stored procedures + functions. Routines come from `pg_catalog.pg_proc` keyed
-- by `prokind` (`p` procedure, `f` function, `a` aggregate, `w` window), with
-- their DDL read via `pg_get_functiondef(oid)`. We list only plain procedures +
-- functions (`prokind IN ('f','p')`); aggregate/window entries are excluded
-- because `pg_get_functiondef` raises on them. `prokind` is postgres 11+; earlier
-- servers used `proisagg` and had no procedures, which we don't target.
local procedures_query = [[
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
local function routine_definition(schema, name, _kind)
  return string.format(
    [[SELECT pg_get_functiondef(p.oid)
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = '%s' AND p.proname = '%s';]],
    parse.sql_squote(schema),
    parse.sql_squote(name)
  )
end

-- "Script As" (SSMS-style DDL scripting) ------------------------------------
--
-- Postgres has no CREATE-vs-ALTER split for a routine body (a function/procedure
-- is redefined with CREATE OR REPLACE; `ALTER FUNCTION` only touches attributes),
-- so the action set is postgres-native: CREATE OR REPLACE / DROP / DROP And
-- CREATE / EXECUTE. Every statement is built server-side (postgres' catalog
-- functions handle overloading and comma-bearing types like `numeric(10,2)`
-- correctly, which Lua-side parsing would not), so each `build` just returns the
-- fetched text and the generic `M.text` parser reassembles it. Statements are
-- emitted per overload (a name can resolve to several functions).

---@private
-- The pg_proc row(s) for one (schema, name): the shared FROM/WHERE every builder
-- below hangs off. `p` is the proc, `n` its namespace; identifiers are escaped
-- for the single-quoted literals.
---@param schema string
---@param name string
---@return string
local function proc_source(schema, name)
  return table.concat({
    'FROM pg_catalog.pg_proc p',
    'JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace',
    string.format("WHERE n.nspname = '%s' AND p.proname = '%s'", parse.sql_squote(schema), parse.sql_squote(name)),
    'ORDER BY p.oid',
  }, '\n')
end

---@private
-- `DROP FUNCTION`/`DROP PROCEDURE schema.name(identity_args);` per overload --
-- the identity args (from `pg_get_function_identity_arguments`) disambiguate
-- overloaded routines.
---@param schema string
---@param name string
---@return string
local function drop_query(schema, name)
  return table.concat({
    "SELECT 'DROP ' || CASE p.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END",
    "  || ' ' || quote_ident(n.nspname) || '.' || quote_ident(p.proname)",
    "  || '(' || pg_get_function_identity_arguments(p.oid) || ');'",
    proc_source(schema, name),
  }, '\n')
end

---@private
-- The DROP statement + a blank line + the CREATE OR REPLACE definition, per
-- overload.
---@param schema string
---@param name string
---@return string
local function drop_and_create_query(schema, name)
  return table.concat({
    "SELECT 'DROP ' || CASE p.prokind WHEN 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END",
    "  || ' ' || quote_ident(n.nspname) || '.' || quote_ident(p.proname)",
    "  || '(' || pg_get_function_identity_arguments(p.oid) || ');' || E'\\n\\n'",
    '  || pg_get_functiondef(p.oid)',
    proc_source(schema, name),
  }, '\n')
end

---@private
-- A runnable call stub per overload: `CALL` for a procedure, `SELECT * FROM` for
-- a set-returning function, else `SELECT`. Each input argument (IN/INOUT/VARIADIC,
-- via `proargmodes`) becomes a `name => :name` bind placeholder -- so running the
-- stub prompts for each value -- with its type as a trailing comment. Positional
-- (unnamed) args fall back to `:argN`. No-arg routines get `()`.
---@param schema string
---@param name string
---@return string
local function execute_query(schema, name)
  return table.concat({
    'SELECT',
    "  CASE p.prokind WHEN 'p' THEN 'CALL '",
    "    ELSE CASE WHEN p.proretset THEN 'SELECT * FROM ' ELSE 'SELECT ' END END",
    "  || quote_ident(n.nspname) || '.' || quote_ident(p.proname)",
    '  || COALESCE(',
    "       E'(\\n    ' || (",
    '         SELECT string_agg(',
    "           CASE WHEN COALESCE(a.argname, '') <> '' THEN a.argname || ' => ' ELSE '' END",
    "           || ':' || CASE WHEN COALESCE(a.argname, '') <> '' THEN a.argname ELSE 'arg' || a.ord END",
    "           || '  -- ' || format_type(a.argtype, NULL),",
    "           E'\\n    , ' ORDER BY a.ord",
    '         )',
    '         FROM unnest(',
    '                COALESCE(p.proallargtypes, p.proargtypes::oid[]),',
    '                COALESCE(p.proargnames, ARRAY[]::text[]),',
    '                COALESCE(p.proargmodes, ARRAY[]::"char"[])',
    '              ) WITH ORDINALITY AS a(argtype, argname, argmode, ord)',
    "         WHERE COALESCE(a.argmode, 'i') IN ('i', 'b', 'v')",
    "       ) || E'\\n)',",
    "       '()'",
    '     )',
    "  || ';'",
    proc_source(schema, name),
  }, '\n')
end

---@private
-- Every postgres action builds its statement server-side, so it needs no `build`
-- -- the generic default (return the fetched, `M.text`-reassembled result) applies.
---@type DadbodUI.RoutineScripts
local routine_scripts = {
  actions = {
    { label = 'CREATE OR REPLACE To', query = routine_definition },
    { label = 'DROP To', query = drop_query },
    { label = 'DROP And CREATE To', query = drop_and_create_query },
    { label = 'EXECUTE To', query = execute_query },
  },
}

---@private
local foreign_key_query = [[
SELECT ccu.table_name AS foreign_table_name, ccu.column_name AS foreign_column_name, ccu.table_schema as foreign_table_schema
FROM
    information_schema.table_constraints AS tc
    JOIN information_schema.key_column_usage AS kcu
      ON tc.constraint_name = kcu.constraint_name
    JOIN information_schema.constraint_column_usage AS ccu
      ON ccu.constraint_name = tc.constraint_name
WHERE constraint_type = 'FOREIGN KEY' and kcu.column_name = '{col_name}' LIMIT 1]]

---@private
local basic_helper_foreign_key_query = table.concat({
  'SELECT tc.constraint_name, tc.table_name, kcu.column_name, ccu.table_name AS foreign_table_name, ccu.column_name AS foreign_column_name, rc.update_rule, rc.delete_rule',
  'FROM',
  '     information_schema.table_constraints AS tc',
  '     JOIN information_schema.key_column_usage AS kcu',
  '       ON tc.constraint_name = kcu.constraint_name',
  '     JOIN information_schema.referential_constraints as rc',
  '       ON tc.constraint_name = rc.constraint_name',
  '     JOIN information_schema.constraint_column_usage AS ccu',
  '       ON ccu.constraint_name = tc.constraint_name',
  '',
}, '\n')

---@type DadbodUI.Adapter
return {
  name = 'postgres',
  aliases = { 'postgresql' },

  ---@param config? DadbodUI.Config
  ---@return DadbodUI.SchemaAdapter
  schema = function(config)
    local use_views = config == nil or config.use_postgres_views
    return {
      -- `-A` unaligned, `-t` tuples-only: machine-readable pipe-separated rows
      -- with no header line and no `(N rows)` footer, so the parser needs no
      -- slice calibration against psql's human framing.
      args = { '-A', '-t', '-c' },
      schemes_query = list_schema_query,
      schemes_tables_query = use_views and tables_and_views_query or tables_query,
      procedures_query = procedures_query,
      routine_definition = routine_definition,
      routine_scripts = routine_scripts,
      foreign_key_query = foreign_key_query,
      select_foreign_key_query = 'select * from "%s"."%s" where "%s" = %s',
      cell_line_number = 2,
      cell_line_pattern = '^-\\++-\\+',
      layout_flag = '\\x',
      parse_results = function(results, min_len)
        local nonempty = vim.tbl_filter(function(row)
          return row ~= ''
        end, results)
        return parse.results_parser(nonempty, '|', min_len)
      end,
      default_scheme = 'public',
      quote = true,
    }
  end,

  table_helpers = {
    List = 'select * from {optional_schema}"{table}" LIMIT 200',
    Columns = "select * from information_schema.columns where table_name='{table}' and table_schema='{schema}'",
    Indexes = "SELECT * FROM pg_indexes where tablename='{table}' and schemaname='{schema}'",
    ['Foreign Keys'] = basic_helper_foreign_key_query
      .. "WHERE constraint_type = 'FOREIGN KEY'\nand tc.table_name = '{table}'\nand tc.table_schema = '{schema}'",
    References = basic_helper_foreign_key_query
      .. "WHERE constraint_type = 'FOREIGN KEY'\nand ccu.table_name = '{table}'\nand tc.table_schema = '{schema}'",
    ['Primary Keys'] = "SELECT * FROM information_schema.table_constraints WHERE constraint_type = 'PRIMARY KEY' AND table_schema = '{schema}' AND table_name = '{table}'",
  },

  explain = { plain = 'EXPLAIN {sql}', analyze = 'EXPLAIN ANALYZE {sql}' },

  pagination = 'limit_offset',

  -- Plain SQL: the classifier's shared core applies as-is.
  statements = {},

  -- Export flags begin with `--no-psqlrc` so a user's ~/.psqlrc cannot inject
  -- lines (e.g. `\timing`) into the strictly-parsed delimited output.
  export = {
    stdin = false,
    extract = { '--no-psqlrc', '--csv', '-c' },
    native = { csv = { '--no-psqlrc', '--csv', '-c' }, html = { '--no-psqlrc', '-H', '-c' } },
  },
}
