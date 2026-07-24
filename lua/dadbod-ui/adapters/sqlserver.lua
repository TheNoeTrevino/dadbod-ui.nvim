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

-- "Script As" (SSMS-style DDL scripting) ------------------------------------
--
-- The drawer turns each stored procedure/function into a "Script As" submenu
-- (CREATE / ALTER / CREATE OR ALTER / DROP / DROP And CREATE / EXECUTE). The
-- generic flow lives in `dadbod-ui.script_as`; everything SQL-Server
-- specific -- the source + parameter queries, their output parsers, and the
-- text transforms -- lives here so the capability is one file per adapter.

---@private
-- Bracket-quote `[schema].[name]` so a dotted/spaced identifier still resolves,
-- doubling any `]` inside a part (`parse.sql_bracket`). The result is meant to be
-- embedded inside a single-quoted string literal, so callers wrap it with
-- `parse.sql_squote`.
---@param schema string
---@param name string
---@return string
local function qualify(schema, name)
  return string.format('[%s].[%s]', parse.sql_bracket(schema), parse.sql_bracket(name))
end

---@private
-- Replace the first whole-word (case-insensitive) `CREATE` with `replacement`,
-- leaving everything after it untouched -- this is what turns a fetched
-- `CREATE PROCEDURE ...` definition into an `ALTER` / `CREATE OR ALTER` one.
-- Returns the string unchanged when no `CREATE` keyword is present (e.g. an
-- encrypted module returns no readable header).
---@param definition string
---@param replacement string
---@return string
local function swap_create(definition, replacement)
  local out, n = definition:gsub('%f[%a][Cc][Rr][Ee][Aa][Tt][Ee]%f[%A]', replacement, 1)
  return n > 0 and out or definition
end

---@private
-- `DROP PROCEDURE`/`DROP FUNCTION [schema].[name]` for the routine in `ctx`.
---@param ctx DadbodUI.ScriptCtx
---@return string
local function drop_statement(ctx)
  return string.format('DROP %s %s', parse.routine_verb(ctx.kind), qualify(ctx.schema, ctx.name))
end

---@private
-- The routine's stored source, byte-for-byte, from `sys.sql_modules.definition`
-- (fetched with `definition_args` below). The alternatives corrupt the text in
-- transit: `sp_helptext` re-chops it into ~255-char rows, splitting a longer
-- source line mid-token, and any (max) column read under the adapter's default
-- args is cut at sqlcmd's 256-char display width. `definition IS NOT NULL`
-- drops encrypted modules, so they surface as "could not script" rather than a
-- literal `NULL` script; `SET NOCOUNT ON` drops the "(N rows affected)" tail.
---@param schema string
---@param name string
---@return string
local function definition_query(schema, name)
  return string.format(
    "SET NOCOUNT ON; SELECT definition FROM sys.sql_modules WHERE object_id = OBJECT_ID('%s') AND definition IS NOT NULL",
    parse.sql_squote(qualify(schema, name))
  )
end

---@private
-- sqlcmd args for the definition fetch, replacing the adapter's defaults: `-y 0`
-- lifts the 256-char truncation of (max) columns by switching sqlcmd into a raw
-- streaming mode. That mode rejects the default formatting flags outright (`-y`
-- is mutually exclusive with both `-W` and `-h-1`) and needs neither: it prints
-- the bare value -- no header, no padding -- which is exactly right for this
-- single-column text fetch. Replacement is whole-list, so the trailing `-Q`
-- (how the query is handed to sqlcmd) restates the adapter `args` below and
-- must stay in sync with any non-formatting flag added there.
local definition_args = { '-y', '0', '-Q' }

---@private
-- (name, type) for each input parameter, ordered as declared. Skips
-- `parameter_id = 0` (a function's return value).
---@param schema string
---@param name string
---@return string
local function params_query(schema, name)
  return table.concat({
    'SET NOCOUNT ON;',
    'SELECT p.name, t.name',
    'FROM sys.parameters p',
    'JOIN sys.types t ON p.user_type_id = t.user_type_id',
    string.format(
      "WHERE p.object_id = OBJECT_ID('%s') AND p.parameter_id > 0",
      parse.sql_squote(qualify(schema, name))
    ),
    'ORDER BY p.parameter_id',
  }, ' ')
end

---@private
-- Parse the `params_query` rows into `{ name, type }` (pipe-separated columns).
---@param lines string[]
---@return DadbodUI.RoutineParam[]
local function parse_params(lines)
  local out = {}
  for _, line in ipairs(lines) do
    if not parse.blank(line) then
      local parts = vim.split(line, '|', { plain = true })
      local pname = vim.trim(parts[1] or '')
      if pname ~= '' then
        out[#out + 1] = { name = pname, type = vim.trim(parts[2] or '') }
      end
    end
  end
  return out
end

---@private
-- The dadbod-ui bind placeholder for a parameter: `@Id` -> `:Id`, so running the
-- stub prompts for `Id` (dadbod-ui's bind-param flow quotes + substitutes it).
---@param param_name string
---@return string
local function bind_name(param_name)
  return (param_name:gsub('^@', ''))
end

---@private
-- A runnable call stub for the routine: an `EXEC` with one `@param = :param` line
-- per parameter (procedures) or a scalar `SELECT name(:arg, ...)` (functions).
-- The `:param` placeholders drive dadbod-ui's bind-param prompt on execute; each
-- parameter's type rides along as a comment. `ctx.data` is the parsed parameters.
---@param ctx DadbodUI.ScriptCtx
---@return string
local function execute_statement(ctx)
  local qualified = qualify(ctx.schema, ctx.name)
  local params = ctx.data or {}
  if ctx.kind == 'function' then
    local args = {}
    for _, p in ipairs(params) do
      args[#args + 1] = string.format(':%s /* %s */', bind_name(p.name), p.type)
    end
    return string.format('SELECT %s(%s)', qualified, table.concat(args, ', '))
  end
  -- A bare `EXEC` falls out naturally when there are no parameters.
  local lines = { 'EXEC ' .. qualified }
  for i, p in ipairs(params) do
    lines[#lines + 1] =
      string.format('    %s = :%s%s -- %s', p.name, bind_name(p.name), i < #params and ',' or '', p.type)
  end
  return table.concat(lines, '\n')
end

---@private
---@type DadbodUI.ScriptActions
local routine_scripts = {
  actions = {
    -- CREATE To needs no `build`: the fetched definition is the script (the
    -- generic default returns `ctx.data`).
    { label = 'CREATE To', query = definition_query, args = definition_args },
    {
      label = 'ALTER To',
      query = definition_query,
      args = definition_args,
      build = function(ctx)
        return swap_create(ctx.data, 'ALTER')
      end,
    },
    {
      label = 'CREATE OR ALTER To',
      query = definition_query,
      args = definition_args,
      build = function(ctx)
        return swap_create(ctx.data, 'CREATE OR ALTER')
      end,
    },
    { label = 'DROP To', build = drop_statement },
    {
      label = 'DROP And CREATE To',
      query = definition_query,
      args = definition_args,
      build = function(ctx)
        return drop_statement(ctx) .. '\nGO\n' .. ctx.data
      end,
    },
    -- EXECUTE To keeps the adapter args: `parse_params` needs their
    -- pipe-separated, whitespace-trimmed row formatting.
    { label = 'EXECUTE To', query = params_query, parse = parse_params, build = execute_statement },
  },
}

-- Table "Script As" ----------------------------------------------------------
--
-- Same fetch-then-assemble shape as the routine actions: the column-list
-- actions read structured rows from `sys.columns` under the adapter's default
-- pipe-separated args and build the statement in Lua. Shared conventions match
-- the other adapters: `INSERT To`/`UPDATE To` exclude identity, computed and
-- rowversion columns (the server supplies their values), `UPDATE To`/`DELETE
-- To` key their WHERE on the primary key with a `<condition>` placeholder
-- fallback, values are `:name` binds with the type as a trailing comment.

---@private
-- The live columns in declared order: name, rendered type (length via
-- `COLUMNPROPERTY(..., 'charmaxlen')`, which already reports characters -- no
-- manual nvarchar byte-halving), the server-supplied flags, and primary-key
-- membership via the PK index.
---@param schema string
---@param name string
---@return string
local function table_columns_query(schema, name)
  return table.concat({
    'SET NOCOUNT ON;',
    'SELECT c.name,',
    "  t.name + CASE WHEN t.name IN ('varchar','char','varbinary','nvarchar','nchar')",
    "      THEN '(' + CASE WHEN c.max_length = -1 THEN 'MAX'",
    "        ELSE CAST(COLUMNPROPERTY(c.object_id, c.name, 'charmaxlen') AS varchar) END + ')'",
    "    WHEN t.name IN ('decimal','numeric')",
    "      THEN '(' + CAST(c.precision AS varchar) + ',' + CAST(c.scale AS varchar) + ')'",
    "    WHEN t.name IN ('datetime2','datetimeoffset','time')",
    "      THEN '(' + CAST(c.scale AS varchar) + ')'",
    "    ELSE '' END,",
    '  c.is_identity, c.is_computed,',
    "  CASE WHEN t.name IN ('timestamp','rowversion') THEN 1 ELSE 0 END,",
    '  CASE WHEN ic.column_id IS NOT NULL THEN 1 ELSE 0 END',
    'FROM sys.columns c',
    'JOIN sys.types t ON t.user_type_id = c.user_type_id',
    'LEFT JOIN sys.indexes pk ON pk.object_id = c.object_id AND pk.is_primary_key = 1',
    'LEFT JOIN sys.index_columns ic ON ic.object_id = c.object_id AND ic.index_id = pk.index_id AND ic.column_id = c.column_id',
    string.format("WHERE c.object_id = OBJECT_ID('%s')", parse.sql_squote(qualify(schema, name))),
    'ORDER BY c.column_id',
  }, '\n')
end

---@private
-- One fetched column. `generated` covers everything the server supplies itself
-- (identity, computed, rowversion) -- excluded from INSERT/UPDATE.
---@class DadbodUI.SqlserverColumn
---@field name string
---@field type string
---@field pk boolean
---@field generated boolean

---@private
-- Parse the pipe-separated `table_columns_query` rows into structured columns.
---@param lines string[]
---@return DadbodUI.SqlserverColumn[]
local function parse_table_columns(lines)
  local out = {}
  for _, line in ipairs(lines) do
    if not parse.blank(line) then
      local f = vim.split(line, '|', { plain = true })
      local cname = vim.trim(f[1] or '')
      if cname ~= '' then
        out[#out + 1] = {
          name = cname,
          type = vim.trim(f[2] or ''),
          generated = vim.trim(f[3] or '') == '1' or vim.trim(f[4] or '') == '1' or vim.trim(f[5] or '') == '1',
          pk = vim.trim(f[6] or '') == '1',
        }
      end
    end
  end
  return out
end

---@private
-- The `WHERE` body keyed on the primary key, or the placeholder fallback. The
-- fallbacks annotate with block comments: a `--` comment would swallow the
-- statement's trailing `;`.
---@param cols DadbodUI.SqlserverColumn[]
---@return string
local function where_by_pk(cols)
  local keys = vim.tbl_filter(function(c)
    return c.pk
  end, cols)
  if #keys == 0 then
    return '<condition>  /* no primary key */'
  end
  return table.concat(
    vim.tbl_map(function(c)
      return string.format('[%s] = :%s', parse.sql_bracket(c.name), c.name)
    end, keys),
    '\n  AND '
  )
end

---@private
-- The columns the user supplies values for: everything server-generated drops.
---@param cols DadbodUI.SqlserverColumn[]
---@return DadbodUI.SqlserverColumn[]
local function writable(cols)
  return vim.tbl_filter(function(c)
    return not c.generated
  end, cols)
end

---@private
-- Every query-backed action fetches the same column rows; `build` receives them
-- as `ctx.data`. An empty fetch (unknown table) yields nil -> the generic
-- "Could not script" notification.
---@type DadbodUI.ScriptActions
local table_scripts = {
  actions = {
    {
      label = 'DROP To',
      ---@param ctx DadbodUI.ScriptCtx
      build = function(ctx)
        return string.format('DROP TABLE %s;', qualify(ctx.schema, ctx.name))
      end,
    },
    {
      label = 'SELECT To',
      query = table_columns_query,
      parse = parse_table_columns,
      ---@param ctx DadbodUI.ScriptCtx
      build = function(ctx)
        if #ctx.data == 0 then
          return nil
        end
        local names = vim.tbl_map(function(c)
          return string.format('[%s]', parse.sql_bracket(c.name))
        end, ctx.data)
        return string.format('SELECT %s\nFROM %s;', table.concat(names, '\n     , '), qualify(ctx.schema, ctx.name))
      end,
    },
    {
      label = 'INSERT To',
      query = table_columns_query,
      parse = parse_table_columns,
      ---@param ctx DadbodUI.ScriptCtx
      build = function(ctx)
        local cols = writable(ctx.data)
        if #cols == 0 then
          return nil
        end
        local names = vim.tbl_map(function(c)
          return string.format('[%s]', parse.sql_bracket(c.name))
        end, cols)
        local values = vim.tbl_map(function(c)
          return string.format(':%s  -- %s', c.name, c.type)
        end, cols)
        return string.format(
          'INSERT INTO %s (\n    %s\n) VALUES (\n    %s\n);',
          qualify(ctx.schema, ctx.name),
          table.concat(names, '\n  , '),
          table.concat(values, '\n  , ')
        )
      end,
    },
    {
      label = 'UPDATE To',
      query = table_columns_query,
      parse = parse_table_columns,
      ---@param ctx DadbodUI.ScriptCtx
      build = function(ctx)
        if #ctx.data == 0 then
          return nil
        end
        local sets = vim.tbl_map(
          function(c)
            return string.format('[%s] = :%s  -- %s', parse.sql_bracket(c.name), c.name, c.type)
          end,
          vim.tbl_filter(function(c)
            return not c.pk
          end, writable(ctx.data))
        )
        return string.format(
          'UPDATE %s\nSET %s\nWHERE %s;',
          qualify(ctx.schema, ctx.name),
          #sets > 0 and table.concat(sets, '\n  , ') or '<column> = :value  /* no updatable columns */',
          where_by_pk(ctx.data)
        )
      end,
    },
    {
      label = 'DELETE To',
      query = table_columns_query,
      parse = parse_table_columns,
      ---@param ctx DadbodUI.ScriptCtx
      build = function(ctx)
        if #ctx.data == 0 then
          return nil
        end
        return string.format('DELETE FROM %s\nWHERE %s;', qualify(ctx.schema, ctx.name), where_by_pk(ctx.data))
      end,
    },
  },
}

---@type DadbodUI.Adapter
return {
  name = 'sqlserver',

  -- Plain SQL: the classifier's shared core applies as-is (the core already
  -- guards TOP and strips [bracket] identifiers).
  statements = {},

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
      -- DDL. Known caveat: this query runs through vim-dadbod's own argv (a plain
      -- query buffer), where `definition_args` cannot apply, so its output is cut
      -- at sqlcmd's 256-char display width -- "Script As" is the full-fidelity path.
      procedures_query = 'SELECT routine_schema, routine_name, LOWER(routine_type) FROM INFORMATION_SCHEMA.ROUTINES '
        .. "WHERE routine_type IN ('PROCEDURE', 'FUNCTION') ORDER BY routine_schema, routine_name",
      ---@param schema string
      ---@param name string
      ---@param _kind string
      ---@return string
      routine_definition = function(schema, name, _kind)
        -- `qualify` bracket-quotes each part (`[schema].[name]`) so a schema/routine
        -- name containing a space or a dot still resolves -- unquoted, `OBJECT_ID`
        -- would parse the dot as the schema separator and return NULL, silently
        -- yielding an empty definition. `sql_squote` then escapes the whole
        -- bracket-quoted literal for the outer single-quoted string.
        return string.format("SELECT OBJECT_DEFINITION(OBJECT_ID('%s'))", parse.sql_squote(qualify(schema, name)))
      end,
      routine_scripts = routine_scripts,
      table_scripts = table_scripts,
      foreign_key_query = foreign_key_query,
      select_foreign_key_query = 'select * from %s.%s where %s = %s',
      cell_line_number = 2,
      cell_line_pattern = '^-\\+.-\\+',
      parse_results = function(results, min_len)
        return parse.results_parser(parse.vslice(results, 0, -3), '|', min_len)
      end,
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
