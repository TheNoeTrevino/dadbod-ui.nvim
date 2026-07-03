-- SQLite dbout-navigation metadata (tables-only path)

---@private
local parse = require('dadbod-ui.schemas.parse')

---@private
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

---@private
-- sqlite's schema entry provides the dbout-only fields below (deliberately NO
-- `schemes_query`, so sqlite stays the tables-only drawer path) to support the
-- foreign-key jump and cell/header navigation in sqlite result buffers. dadbod
-- renders sqlite results with `-column -header`, i.e. space-aligned columns under
-- a `---` underline -- hence cell_line_number 2 and the dash-rule pattern, and a
-- parser that drops the header + underline and splits on the column gaps.
---@param config? DadbodUI.Config
---@return DadbodUI.SchemaAdapter
return function(config)
  return {
    foreign_key_query = sqlite_foreign_key_query,
    select_foreign_key_query = 'select * from "%s"."%s" where "%s" = %s',
    cell_line_number = 2,
    cell_line_pattern = '^-\\+\\( \\+-\\+\\)*\\s*$',
    parse_results = function(results, min_len)
      return parse.results_parser(parse.vslice(results, 2), '\\s\\s\\+', min_len)
    end,
  }
end
