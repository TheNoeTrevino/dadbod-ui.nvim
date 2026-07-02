---@mod dadbod-ui.schemas.clickhouse  ClickHouse schema/table introspection

---@private
local parse = require('dadbod-ui.schemas.parse')

---@private
---@param config? DadbodUI.Config
---@return DadbodUI.SchemaAdapter
return function(config)
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
end
