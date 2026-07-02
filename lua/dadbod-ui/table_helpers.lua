-- Per-adapter table-helper templates (data)
--
-- Faithful port of vim-dadbod-ui's `autoload/db_ui/table_helpers.vim`. Each
-- adapter maps a helper name (`List`, `Columns`, `Indexes`, ...) to a SQL
-- template containing placeholders (`{table}`, `{schema}`, `{optional_schema}`,
-- ...). M6 only needs the helper *names* -- they are rendered as the children of
-- an expanded table -- so this milestone ports the data verbatim; placeholder
-- substitution and execution land in M8. The templates are copied exactly so
-- that later work has nothing to re-derive.

---@class DadbodUI.TableHelpersModule
---@field get fun(scheme: string, config?: DadbodUI.Config): table<string, string>
---@field ordered_names fun(helper_map: table<string, string>, order?: string[]): string[]

---@type DadbodUI.TableHelpersModule
---@diagnostic disable-next-line: missing-fields
local M = {}

---@private
local basic_foreign_key_query = table.concat({
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

---@private
local bigquery = {
  List = 'select * from {optional_schema}{table} LIMIT 200',
  Columns = "select * from {schema}.INFORMATION_SCHEMA.COLUMNS where table_name='{table}'",
}

---@private
local postgres = {
  List = 'select * from {optional_schema}"{table}" LIMIT 200',
  Columns = "select * from information_schema.columns where table_name='{table}' and table_schema='{schema}'",
  Indexes = "SELECT * FROM pg_indexes where tablename='{table}' and schemaname='{schema}'",
  ['Foreign Keys'] = basic_foreign_key_query
    .. "WHERE constraint_type = 'FOREIGN KEY'\nand tc.table_name = '{table}'\nand tc.table_schema = '{schema}'",
  References = basic_foreign_key_query
    .. "WHERE constraint_type = 'FOREIGN KEY'\nand ccu.table_name = '{table}'\nand tc.table_schema = '{schema}'",
  ['Primary Keys'] = "SELECT * FROM information_schema.table_constraints WHERE constraint_type = 'PRIMARY KEY' AND table_schema = '{schema}' AND table_name = '{table}'",
}

---@private
local mysql = {
  List = 'SELECT * from {optional_schema}`{table}` LIMIT 200',
  Columns = 'DESCRIBE {optional_schema}`{table}`',
  Indexes = 'SHOW INDEXES FROM {optional_schema}`{table}`',
  ['Foreign Keys'] = "SELECT * FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS WHERE TABLE_SCHEMA = '{schema}' AND TABLE_NAME = '{table}' AND CONSTRAINT_TYPE = 'FOREIGN KEY'",
  ['Primary Keys'] = "SELECT * FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS WHERE TABLE_SCHEMA = '{schema}' AND TABLE_NAME = '{table}' AND CONSTRAINT_TYPE = 'PRIMARY KEY'",
}

---@private
-- Oracle helpers share a common FROM/qualify fragment and are each wrapped with
-- SQL*Plus COLUMN formatting, exactly as the original builds them in a loop.
local oracle_from = table.concat({
  'FROM all_constraints N',
  'JOIN all_cons_columns L',
  '\tON N.constraint_name = L.constraint_name',
  '\tAND N.owner = L.owner',
}, '\n')

---@private
local oracle_qualify_and_order_by = table.concat({
  "L.table_name = '{table}'",
  'ORDER BY',
  '\t',
}, '\n')

---@private
local oracle_key_cmd = table.concat({
  'SELECT',
  '\tL.table_name,',
  '\tL.column_name',
  oracle_from,
  'WHERE',
  "\tN.constraint_type = '%s'",
  '\tAND ' .. oracle_qualify_and_order_by .. 'L.column_name',
}, '\n')

---@private
local oracle = {
  Columns = 'DESCRIBE "{schema}"."{table}"',
  ['Foreign Keys'] = oracle_key_cmd:format('R'),
  Indexes = table.concat({
    'SELECT DISTINCT',
    '\tN.owner,',
    '\tN.index_name,',
    '\tN.constraint_type',
    oracle_from,
    'WHERE',
    '\t' .. oracle_qualify_and_order_by .. 'N.index_name',
  }, '\n'),
  List = 'SELECT * FROM "{schema}"."{table}"',
  ['Primary Keys'] = oracle_key_cmd:format('P'),
  References = table.concat({
    'SELECT',
    '\tRFRING.owner,',
    '\tRFRING.table_name,',
    '\tRFRING.column_name',
    'FROM all_cons_columns RFRING',
    'JOIN all_constraints N',
    '\tON RFRING.constraint_name = N.constraint_name',
    'JOIN all_cons_columns RFRD',
    '\tON N.r_constraint_name = RFRD.constraint_name',
    'JOIN all_users U',
    '\tON N.owner = U.username',
    'WHERE',
    "\tN.constraint_type = 'R'",
    'AND',
    "\tU.common = 'NO'",
    'AND',
    "\tRFRD.owner = '{schema}'",
    'AND',
    "\tRFRD.table_name = '{table}'",
    'ORDER BY',
    '\tRFRING.owner,',
    '\tRFRING.table_name,',
    '\tRFRING.column_name',
  }, '\n'),
}

for helper, query in pairs(oracle) do
  oracle[helper] = table.concat({
    'SET linesize 4000;',
    'SET pagesize 4000;',
    '',
    'COLUMN column_name FORMAT a20;',
    'COLUMN constraint_type FORMAT a20;',
    'COLUMN index_name FORMAT a20;',
    'COLUMN owner FORMAT a20;',
    'COLUMN table_name FORMAT a20;',
    '',
    query,
    ';',
  }, '\n')
end

---@private
local sqlserver_column_summary_query = table.concat({
  "select c.column_name + ' (' + ",
  "    isnull(( select 'PK, ' from information_schema.table_constraints as k join information_schema.key_column_usage as kcu on k.constraint_name = kcu.constraint_name where constraint_type='PRIMARY KEY' and k.table_name = c.table_name and kcu.column_name = c.column_name), '') + ",
  "    isnull(( select 'FK, ' from information_schema.table_constraints as k join information_schema.key_column_usage as kcu on k.constraint_name = kcu.constraint_name where constraint_type='FOREIGN KEY' and k.table_name = c.table_name and kcu.column_name = c.column_name), '') + ",
  "    data_type + coalesce('(' + rtrim(cast(character_maximum_length as varchar)) + ')','(' + rtrim(cast(numeric_precision as varchar)) + ',' + rtrim(cast(numeric_scale as varchar)) + ')','(' + rtrim(cast(datetime_precision as varchar)) + ')','') + ', ' + ",
  "    case when is_nullable = 'YES' then 'null' else 'not null' end + ')' as Columns ",
  " from information_schema.columns c where c.table_name='{table}' and c.TABLE_SCHEMA = '{schema}'",
}, '\n')

---@private
local sqlserver_foreign_keys_query = table.concat({
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
local sqlserver_references_query = table.concat({
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
local sqlserver_primary_keys = table.concat({
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
local sqlserver_constraints_query = table.concat({
  ' SELECT u.CONSTRAINT_NAME, c.CHECK_CLAUSE FROM INFORMATION_SCHEMA.CONSTRAINT_TABLE_USAGE u ',
  '     inner join INFORMATION_SCHEMA.CHECK_CONSTRAINTS c on u.CONSTRAINT_NAME = c.CONSTRAINT_NAME ',
  " where TABLE_NAME = '{table}' and u.TABLE_SCHEMA = '{schema}'",
}, '\n')

---@private
local sqlserver = {
  List = 'select top 200 * from {optional_schema}[{table}]',
  Columns = sqlserver_column_summary_query,
  Indexes = "exec sp_helpindex '{schema}.{table}'",
  ['Foreign Keys'] = sqlserver_foreign_keys_query,
  References = sqlserver_references_query,
  ['Primary Keys'] = sqlserver_primary_keys,
  Constraints = sqlserver_constraints_query,
  Describe = "exec sp_help '{schema}.{table}'",
}

---@private
local clickhouse = {
  List = 'select * from `{schema}`.`{table}` limit 100 Format PrettyCompactMonoBlock',
  Columns = "select name from system.columns where database='{schema}' and table='{table}'",
}

---@private
-- scheme -> helper map. SQLite's `List` is the user's default query, so it is
-- filled in at `get` time from config; the rest are static.
local helpers = {
  bigquery = bigquery,
  postgresql = postgres,
  mysql = mysql,
  mariadb = mysql,
  oracle = oracle,
  sqlserver = sqlserver,
  clickhouse = clickhouse,
  mongodb = { List = '{table}.find()' },
}
helpers.postgres = helpers.postgresql

---@private
-- Bidirectional alias map: an override under one name also applies to its twin.
local scheme_map = {
  postgres = 'postgresql',
  postgresql = 'postgres',
  sqlite3 = 'sqlite',
  sqlite = 'sqlite3',
}

--- The helper map for `scheme`, merged with user overrides. Port of
--- `db_ui#table_helpers#get`: the adapter defaults are overlaid with
--- `config.table_helpers[scheme]` (and the aliased scheme), helpers set to the
--- empty string are dropped, and an all-empty result falls back to a blank
--- `List` so a table always renders at least one child.
---@param scheme string
---@param config? DadbodUI.Config
---@return table<string, string>
function M.get(scheme, config)
  config = config or { default_query = 'SELECT * from "{table}" LIMIT 200;', table_helpers = {} }
  local user = config.table_helpers or {}

  local base = helpers[scheme]
  if scheme == 'sqlite' or scheme == 'sqlite3' then
    -- SQLite's List comes from the configured default query; built here so a
    -- non-sqlite call never allocates it.
    base = {
      List = config.default_query,
      Columns = "SELECT * FROM pragma_table_info('{table}')",
      Indexes = "SELECT * FROM pragma_index_list('{table}')",
      ['Foreign Keys'] = "SELECT * FROM pragma_foreign_key_list('{table}')",
      ['Primary Keys'] = "SELECT * FROM pragma_index_list('{table}') WHERE origin = 'pk'",
    }
  end

  local result = vim.tbl_extend('force', {}, base or { List = '' }, user[scheme] or {})
  local mapped = scheme_map[scheme]
  if mapped then
    result = vim.tbl_extend('force', result, user[mapped] or {})
  end

  for key, value in pairs(result) do
    if value == '' then
      result[key] = nil
    end
  end

  if vim.tbl_isempty(result) then
    result.List = ''
  end

  return result
end

---@private
-- Canonical display order for table helpers. `List` always comes first; the
-- rest follow a fixed, schema-independent sequence. Names not listed here
-- (adapter extras like `Constraints`/`Describe`, and any user-added helper)
-- sort alphabetically after these, so the drawer order is fully deterministic
-- regardless of `pairs()` iteration order.
local helper_order = { 'List', 'Columns', 'Indexes', 'Primary Keys', 'Foreign Keys', 'References' }

--- The names in `helper_map`, ordered for display: `order` first (only names
--- actually present in `helper_map`, in `order` sequence -- names absent from
--- `helper_map` are skipped, no blank nodes), then any remaining present
--- helpers (adapter extras, or user-added helpers not named in `order`)
--- alphabetically, so the tail stays deterministic regardless of `pairs()`
--- iteration order. `order` defaults to the module's canonical sequence, so
--- existing callers (and the default `table_helpers_order` config) are
--- unaffected; an empty or all-unknown `order` degrades gracefully to "every
--- present helper, alphabetically".
---@param helper_map table<string, string>
---@param order? string[]
---@return string[]
function M.ordered_names(helper_map, order)
  order = order or helper_order
  local is_ordered = {} -- name -> true, for the "already placed by `order`" test
  for _, name in ipairs(order) do
    is_ordered[name] = true
  end
  -- Names from `order` that are present, kept in `order` sequence.
  local ordered = vim
    .iter(order)
    :filter(function(name)
      return helper_map[name] ~= nil
    end)
    :totable()
  -- Everything else (adapter extras, user-added helpers not named in `order`),
  -- sorted alphabetically.
  local extras = vim
    .iter(vim.tbl_keys(helper_map))
    :filter(function(name)
      return not is_ordered[name]
    end)
    :totable()
  table.sort(extras)
  return vim.list_extend(ordered, extras)
end

return M
