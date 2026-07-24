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
---@type DadbodUI.ScriptActions
local routine_scripts = {
  actions = {
    { label = 'CREATE OR REPLACE To', query = routine_definition },
    { label = 'DROP To', query = drop_query },
    { label = 'DROP And CREATE To', query = drop_and_create_query },
    { label = 'EXECUTE To', query = execute_query },
  },
}

-- Table "Script As" -----------------------------------------------------------
--
-- Same shape as the routine actions: every statement is built server-side (the
-- catalog renders identifiers via `quote_ident` and types via `format_type`, so
-- no Lua string assembly), except the name-only DROP. `INSERT To`/`UPDATE To`
-- exclude identity and generated columns (the server supplies their values);
-- `UPDATE To`/`DELETE To` key their WHERE on the primary key, degrading to a
-- `<condition>` placeholder on a PK-less table.

---@private
-- The rendered `schema.table` identifier expression shared by the builders.
local qualified_table = "quote_ident(n.nspname) || '.' || quote_ident(c.relname)"

---@private
-- The (schema, name) relation joined to its live columns: `c` the relation, `n`
-- its namespace, `a` the attributes in `attnum` order (dropped and system
-- attributes excluded). `with_pk` adds a lateral `pk.is_pk` per attribute
-- (member of the primary-key index) for the UPDATE/DELETE WHERE aggregates.
-- `extra_where` narrows the attribute set (e.g. INSERT excluding identity /
-- generated columns). Identifiers are escaped for the single-quoted literals.
---@param schema string
---@param name string
---@param opts? { with_pk?: boolean, extra_where?: string }
---@return string
local function columns_source(schema, name, opts)
  opts = opts or {}
  local lines = {
    'FROM pg_catalog.pg_class c',
    'JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace',
    'JOIN pg_catalog.pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped',
  }
  if opts.with_pk then
    lines[#lines + 1] = 'CROSS JOIN LATERAL (SELECT EXISTS ('
    lines[#lines + 1] = '  SELECT FROM pg_catalog.pg_index i'
    lines[#lines + 1] = '  WHERE i.indrelid = c.oid AND i.indisprimary AND a.attnum = ANY(i.indkey)'
    lines[#lines + 1] = ') AS is_pk) pk'
  end
  lines[#lines + 1] =
    string.format("WHERE n.nspname = '%s' AND c.relname = '%s'", parse.sql_squote(schema), parse.sql_squote(name))
  if opts.extra_where then
    lines[#lines + 1] = '  ' .. opts.extra_where
  end
  lines[#lines + 1] = 'GROUP BY n.nspname, c.relname'
  return table.concat(lines, '\n')
end

---@private
-- `SELECT <every column>\nFROM schema.table;`
---@param schema string
---@param name string
---@return string
local function select_to_query(schema, name)
  return table.concat({
    "SELECT 'SELECT '",
    "  || string_agg(quote_ident(a.attname), E'\\n     , ' ORDER BY a.attnum)",
    "  || E'\\nFROM ' || " .. qualified_table .. " || ';'",
    columns_source(schema, name),
  }, '\n')
end

---@private
-- `INSERT INTO schema.table (cols) VALUES (:col -- type, ...);` -- identity and
-- generated columns are excluded (the server supplies their values), each value
-- a `:name` bind placeholder with its type as a trailing comment (same
-- convention as the routine `EXECUTE To` stubs).
---@param schema string
---@param name string
---@return string
local function insert_to_query(schema, name)
  return table.concat({
    "SELECT 'INSERT INTO ' || " .. qualified_table .. " || E' (\\n    '",
    "  || string_agg(quote_ident(a.attname), E'\\n  , ' ORDER BY a.attnum)",
    "  || E'\\n) VALUES (\\n    '",
    "  || string_agg(':' || a.attname || '  -- ' || format_type(a.atttypid, a.atttypmod), E'\\n  , ' ORDER BY a.attnum)",
    "  || E'\\n);'",
    columns_source(schema, name, { extra_where = "AND a.attidentity = '' AND a.attgenerated = ''" }),
  }, '\n')
end

---@private
-- The `WHERE <pk> = :pk AND ...` aggregate shared by UPDATE/DELETE, degrading
-- to a placeholder condition when the table has no primary key. The fallbacks
-- annotate with block comments: a `--` comment would swallow the trailing `;`.
local where_by_pk = table.concat({
  "COALESCE(string_agg(quote_ident(a.attname) || ' = :' || a.attname, E'\\n  AND ' ORDER BY a.attnum)",
  "       FILTER (WHERE pk.is_pk), '<condition>  /* no primary key */')",
}, '\n  ')

---@private
-- `UPDATE schema.table SET <non-key cols> WHERE <pk cols>;` -- key columns move
-- to the WHERE, identity/generated columns are excluded from the SET.
---@param schema string
---@param name string
---@return string
local function update_to_query(schema, name)
  return table.concat({
    "SELECT 'UPDATE ' || " .. qualified_table,
    "  || E'\\nSET ' || COALESCE(",
    "       string_agg(quote_ident(a.attname) || ' = :' || a.attname || '  -- ' || format_type(a.atttypid, a.atttypmod),",
    "                  E'\\n  , ' ORDER BY a.attnum)",
    "         FILTER (WHERE NOT pk.is_pk AND a.attidentity = '' AND a.attgenerated = ''),",
    "       '<column> = :value  /* no updatable columns */')",
    "  || E'\\nWHERE ' || " .. where_by_pk,
    "  || ';'",
    columns_source(schema, name, { with_pk = true }),
  }, '\n')
end

---@private
-- `DELETE FROM schema.table WHERE <pk cols>;`
---@param schema string
---@param name string
---@return string
local function delete_to_query(schema, name)
  return table.concat({
    "SELECT 'DELETE FROM ' || " .. qualified_table,
    "  || E'\\nWHERE ' || " .. where_by_pk,
    "  || ';'",
    columns_source(schema, name, { with_pk = true }),
  }, '\n')
end

---@private
-- Query-less: `DROP TABLE "schema"."name";` built from the names alone, no
-- round-trip.
---@param ctx DadbodUI.ScriptCtx
---@return string
local function drop_table_statement(ctx)
  return string.format('DROP TABLE "%s"."%s";', parse.sql_dquote(ctx.schema), parse.sql_dquote(ctx.name))
end

---@private
-- Like the routine actions, every query-backed action needs no `build`/`parse`:
-- the statement text arrives finished from the server.
---@type DadbodUI.ScriptActions
local table_scripts = {
  actions = {
    { label = 'DROP To', build = drop_table_statement },
    { label = 'SELECT To', query = select_to_query },
    { label = 'INSERT To', query = insert_to_query },
    { label = 'UPDATE To', query = update_to_query },
    { label = 'DELETE To', query = delete_to_query },
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
      table_scripts = table_scripts,
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

  explain = {
    plain = 'EXPLAIN {sql}',
    analyze = 'EXPLAIN ANALYZE {sql}',
    json = 'EXPLAIN (FORMAT JSON) {sql}',
    -- ANALYZE executes the statement, so the JSON form runs inside a rolled-back
    -- transaction: analyzing a DML statement must never commit its effects.
    json_analyze = 'BEGIN; EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {sql}; ROLLBACK;',
    -- `-q` suppresses the BEGIN/ROLLBACK command tags, `-A -t` drop psql's
    -- aligned-table framing (the `+` continuation gutter), `--no-psqlrc` keeps a
    -- user's psqlrc from injecting lines -- together stdout is the bare JSON
    -- document. ON_ERROR_STOP makes a SQL error exit non-zero (psql otherwise
    -- exits 0 from a piped script), so failures surface as errors, not as
    -- unparseable output.
    json_args = { '--no-psqlrc', '--set=ON_ERROR_STOP=1', '-q', '-A', '-t' },
    parser = 'dadbod-ui.explain.parsers.postgres',
  },

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
