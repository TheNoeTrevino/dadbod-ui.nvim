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

-- Table "Script As" ----------------------------------------------------------
--
-- Unlike postgres (whose catalog renders finished statements server-side), the
-- column-list actions here fetch structured rows from
-- `information_schema.columns` and assemble in Lua -- mysql has no server-side
-- statement builder to lean on. The shared conventions match: `INSERT
-- To`/`UPDATE To` exclude auto-increment and generated columns, `UPDATE
-- To`/`DELETE To` key their WHERE on the primary key with a `<condition>`
-- placeholder fallback, values are `:name` binds with the type as a trailing
-- comment. No action overrides `args`: the adapter's stdin + `-N` TSV mode is
-- exactly the machine-readable framing the parser wants.

---@private
-- `` `schema`.`name` `` -- or bare `` `name` `` for a db-in-path connection,
-- whose tables carry no schema ('').
---@param schema string
---@param name string
---@return string
local function qualify(schema, name)
  local t = string.format('`%s`', parse.my_backtick(name))
  if schema == '' then
    return t
  end
  return string.format('`%s`.%s', parse.my_backtick(schema), t)
end

---@private
-- The live columns in ordinal order. A db-in-path connection passes schema ''
-- and scopes to the connected database instead.
---@param schema string
---@param name string
---@return string
local function columns_query(schema, name)
  local owner = schema ~= '' and string.format("'%s'", parse.sql_squote(schema)) or 'DATABASE()'
  return table.concat({
    'SELECT column_name, column_type, column_key, extra',
    'FROM information_schema.columns',
    string.format("WHERE table_schema = %s AND table_name = '%s'", owner, parse.sql_squote(name)),
    'ORDER BY ordinal_position',
  }, '\n')
end

---@private
-- One fetched column. `generated` covers everything the server supplies itself
-- (auto_increment + STORED/VIRTUAL generated columns) -- excluded from
-- INSERT/UPDATE. NOT matched: mysql 8 stamps plain expression defaults
-- `DEFAULT_GENERATED`, and those columns are perfectly insertable.
---@class DadbodUI.MysqlColumn
---@field name string
---@field type string
---@field pk boolean
---@field generated boolean

---@private
-- Split the `-N` TSV rows of `columns_query` into structured columns.
---@param lines string[]
---@return DadbodUI.MysqlColumn[]
local function parse_columns(lines)
  return vim
    .iter(lines)
    :filter(function(line)
      return not parse.blank(line)
    end)
    :map(function(line)
      local f = vim.split(line, '\t', { plain = true })
      local extra = f[4] or ''
      return {
        name = f[1],
        type = f[2],
        pk = f[3] == 'PRI',
        generated = extra:find('auto_increment', 1, true) ~= nil
          or extra:find('STORED GENERATED', 1, true) ~= nil
          or extra:find('VIRTUAL GENERATED', 1, true) ~= nil,
      }
    end)
    :totable()
end

---@private
-- The `WHERE` body keyed on the primary key, or the placeholder fallback. The
-- fallbacks annotate with block comments: a `--` comment would swallow the
-- statement's trailing `;`.
---@param cols DadbodUI.MysqlColumn[]
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
      return string.format('`%s` = :%s', parse.my_backtick(c.name), c.name)
    end, keys),
    '\n  AND '
  )
end

---@private
-- The columns the user supplies values for: everything server-generated drops.
---@param cols DadbodUI.MysqlColumn[]
---@return DadbodUI.MysqlColumn[]
local function writable(cols)
  return vim.tbl_filter(function(c)
    return not c.generated
  end, cols)
end

---@private
-- The DDL cell of `SHOW CREATE TABLE` under batch `-N` mode: one
-- `name<TAB>ddl` row whose value has newlines/tabs/backslashes escaped as
-- two-char `\n`/`\t`/`\\` sequences (and NUL as `\0`). Split off the leading
-- name at the first real tab, then unescape in a single pass -- one gsub, so a
-- literal `\\n` correctly becomes `\` + `n`, not a newline.
---@param lines string[]
---@return string|nil
local function parse_show_create(lines)
  local row = vim.iter(lines):find(function(line)
    return not parse.blank(line)
  end)
  if row == nil then
    return nil
  end
  local ddl = row:match('^[^\t]*\t(.*)$') or row
  return (ddl:gsub('\\([nt0\\])', { n = '\n', t = '\t', ['0'] = '\0', ['\\'] = '\\' })) .. ';'
end

---@private
-- Every query-backed action fetches the same column rows (CREATE To fetches the
-- server-rendered DDL instead); `build` receives the parse as `ctx.data`. An
-- empty fetch (unknown table) yields nil -> the generic "Could not script"
-- notification.
---@type DadbodUI.ScriptActions
local table_scripts = {
  actions = {
    {
      -- The server renders the full CREATE TABLE (indexes, constraints, engine,
      -- charset) -- returned verbatim, like every other SHOW CREATE consumer.
      label = 'CREATE To',
      ---@param schema string
      ---@param name string
      query = function(schema, name)
        return 'SHOW CREATE TABLE ' .. qualify(schema, name)
      end,
      parse = parse_show_create,
    },
    {
      label = 'DROP To',
      ---@param ctx DadbodUI.ScriptCtx
      build = function(ctx)
        return string.format('DROP TABLE %s;', qualify(ctx.schema, ctx.name))
      end,
    },
    {
      label = 'SELECT To',
      query = columns_query,
      parse = parse_columns,
      ---@param ctx DadbodUI.ScriptCtx
      build = function(ctx)
        if #ctx.data == 0 then
          return nil
        end
        local names = vim.tbl_map(function(c)
          return string.format('`%s`', parse.my_backtick(c.name))
        end, ctx.data)
        return string.format('SELECT %s\nFROM %s;', table.concat(names, '\n     , '), qualify(ctx.schema, ctx.name))
      end,
    },
    {
      label = 'INSERT To',
      query = columns_query,
      parse = parse_columns,
      ---@param ctx DadbodUI.ScriptCtx
      build = function(ctx)
        local cols = writable(ctx.data)
        if #cols == 0 then
          return nil
        end
        local names = vim.tbl_map(function(c)
          return string.format('`%s`', parse.my_backtick(c.name))
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
      query = columns_query,
      parse = parse_columns,
      ---@param ctx DadbodUI.ScriptCtx
      build = function(ctx)
        if #ctx.data == 0 then
          return nil
        end
        local sets = vim.tbl_map(
          function(c)
            return string.format('`%s` = :%s  -- %s', parse.my_backtick(c.name), c.name, c.type)
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
      query = columns_query,
      parse = parse_columns,
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
  name = 'mysql',

  -- A mysql url that names a database in its path has no schema browsing: the
  -- drawer lists that database's tables directly (see schemas.supports_schemes).
  db_path_lists_tables = true,

  ---@param _config? DadbodUI.Config
  ---@return DadbodUI.SchemaAdapter
  schema = function(_config)
    return {
      -- `-N` (--skip-column-names): machine-readable TSV rows with no header
      -- line, so the parser needs no header-dropping slice.
      args = { '-N' },
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
      table_scripts = table_scripts,
      foreign_key_query = foreign_key_query,
      select_foreign_key_query = 'select * from %s.%s where %s = %s',
      cell_line_number = 3,
      cell_line_pattern = '^+-\\++-\\+',
      layout_flag = '\\G',
      requires_stdin = true,
      parse_results = function(results, min_len)
        return parse.results_parser(results, '\\t', min_len)
      end,
      default_scheme = '',
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

  explain = {
    plain = 'EXPLAIN {sql}',
    analyze = 'EXPLAIN ANALYZE {sql}',
    -- No json_analyze: MySQL's EXPLAIN ANALYZE emits TREE text, never JSON.
    json = 'EXPLAIN FORMAT=JSON {sql}',
    -- dadbod's filter command forces `-t` (boxed table output), which would
    -- frame the JSON in `|` borders; `--skip-table` (later flag wins) undoes
    -- it. `--batch --raw` then prints the JSON cell verbatim (no \n escaping)
    -- and `--skip-column-names` drops the header row.
    json_args = { '--skip-table', '--batch', '--raw', '--skip-column-names' },
    parser = 'dadbod-ui.explain.parsers.mysql',
  },

  pagination = 'limit_comma',

  -- Plain SQL: the classifier's shared core applies as-is.
  statements = {},

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
