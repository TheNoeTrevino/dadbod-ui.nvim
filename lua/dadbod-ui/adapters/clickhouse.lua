-- ClickHouse: introspection, table helpers, explain, pagination

---@private
local parse = require('dadbod-ui.schemas.parse')

---@type DadbodUI.Adapter
return {
  name = 'clickhouse',

  ---@param _config? DadbodUI.Config
  ---@return DadbodUI.SchemaAdapter
  schema = function(_config)
    return {
      args = { '-q' },
      schemes_query = 'SELECT name as schema_name FROM system.databases ORDER BY name',
      schemes_tables_query = 'SELECT database AS table_schema, name AS table_name FROM system.tables ORDER BY table_name',
      cell_line_number = 1,
      cell_line_pattern = '^.*$',
      parse_results = function(results, min_len)
        return parse.results_parser(results, '\\t', min_len)
      end,
      default_scheme = '',
      quote = 1,
    }
  end,

  table_helpers = {
    List = 'select * from `{schema}`.`{table}` limit 100 Format PrettyCompactMonoBlock',
    Columns = "select name from system.columns where database='{schema}' and table='{table}'",
  },

  explain = { plain = 'EXPLAIN {sql}' },

  pagination = 'limit_offset',
}
