-- SQLite: dbout navigation, table helpers, explain, pagination, export
--
-- sqlite has no schema browsing: its `schema` entry deliberately carries NO
-- `schemes_query`, keeping the tables-only drawer path, while still providing
-- the dbout-navigation metadata (foreign-key jump, cell/header nav).

---@private
local parse = require('dadbod-ui.schemas.parse')

---@private
-- The OS null device, used to skip the CLI's user rc file (`-init`). `/dev/null`
-- on unix, `NUL` on Windows.
local NULLDEV = vim.fn.has('win32') == 1 and 'NUL' or '/dev/null'

---@private
-- sqlite has no information_schema, so resolve a column's foreign table globally
-- via the `pragma_foreign_key_list` table-valued function joined over
-- `sqlite_master` -- this matches the `{col_name}`-only interface the other
-- adapters use. The third column is the literal `main` (sqlite's default
-- database) so the postgres-style schema-qualified select template works as-is
-- (`"main"."table"` is valid sqlite).
local foreign_key_query = [[
SELECT fkl."table" AS foreign_table_name, fkl."to" AS foreign_column_name, 'main' AS foreign_table_schema
FROM sqlite_master m
JOIN pragma_foreign_key_list(m.name) fkl
WHERE m.type = 'table' AND fkl."from" = '{col_name}'
LIMIT 1]]

---@type DadbodUI.Adapter
return {
  name = 'sqlite',
  aliases = { 'sqlite3' },

  -- dadbod renders sqlite results with `-column -header`, i.e. space-aligned
  -- columns under a `---` underline -- hence cell_line_number 2 and the dash-rule
  -- pattern, and a parser that drops the header + underline and splits on the
  -- column gaps.
  ---@param _config? DadbodUI.Config
  ---@return DadbodUI.SchemaAdapter
  schema = function(_config)
    return {
      foreign_key_query = foreign_key_query,
      select_foreign_key_query = 'select * from "%s"."%s" where "%s" = %s',
      cell_line_number = 2,
      cell_line_pattern = '^-\\+\\( \\+-\\+\\)*\\s*$',
      parse_results = function(results, min_len)
        return parse.results_parser(parse.vslice(results, 2), '\\s\\s\\+', min_len)
      end,
    }
  end,

  --- dadbod's raw `tables` call lists tables as space-separated strings: split
  --- the chunks apart and sort.
  ---@param raw string[]
  ---@return string[]
  normalize_tables = function(raw)
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
  end,

  --- SQLite's `List` is the user's configured default query, so the helper map
  --- is built per call.
  ---@param config DadbodUI.Config
  ---@return table<string, string>
  table_helpers = function(config)
    return {
      List = config.query.default_query,
      Columns = "SELECT * FROM pragma_table_info('{table}')",
      Indexes = "SELECT * FROM pragma_index_list('{table}')",
      ['Foreign Keys'] = "SELECT * FROM pragma_foreign_key_list('{table}')",
      ['Primary Keys'] = "SELECT * FROM pragma_index_list('{table}') WHERE origin = 'pk'",
    }
  end,

  -- SQLite's `EXPLAIN QUERY PLAN` is the high-level plan; bare `EXPLAIN` dumps
  -- VDBE bytecode and there is no executing/timed form, so no `analyze`.
  explain = { plain = 'EXPLAIN QUERY PLAN {sql}' },

  pagination = 'limit_offset',

  export = {
    -- stdin delivery (not a positional arg): sqlite3 treats a positional SQL
    -- string beginning with `-` (e.g. a `-- comment` line) as an unknown option
    -- and aborts. `-init <nulldev>` skips ~/.sqliterc so it cannot inject
    -- `.nullvalue` etc. into the strictly-parsed output.
    stdin = true,
    extract = { '-init', NULLDEV, '-csv', '-header' },
    native = {
      csv = { '-init', NULLDEV, '-csv', '-header' },
      json = { '-init', NULLDEV, '-json' },
      -- NB: sqlite's `-markdown` is deliberately NOT native. Its column alignment
      -- for numeric cells changed between sqlite3 releases (older builds
      -- left-justify, newer ones right-justify), so the raw passthrough is not
      -- reproducible across environments. The Lua markdown formatter is used
      -- everywhere instead (uniform with postgres/mysql markdown, deterministic
      -- output -- verified in the export integration suite).
      -- NB: sqlite's `-html` is deliberately NOT native. It emits a bare `<TR>`
      -- fragment (no `<table>` wrapper) and renders NULL as the literal text
      -- `null`; the Lua HTML formatter produces a proper `<table><thead><tbody>`
      -- with NULL -> empty, so sqlite HTML always goes through the formatter
      -- (verified in T16). postgres `-H` / mysql `--html` emit full tables and
      -- stay native.
    },
  },
}
