-- BigQuery: introspection, table helpers, pagination
--
-- No explain (BigQuery has no EXPLAIN statement), no export.

---@private
local parse = require('dadbod-ui.schemas.parse')

---@type DadbodUI.Adapter
return {
  name = 'bigquery',

  ---@param _config? DadbodUI.Config
  ---@return DadbodUI.SchemaAdapter
  schema = function(_config)
    local region = vim.g.db_adapter_bigquery_region or 'region-us'
    return {
      callable = 'filter',
      args = { '--format=csv', '--max_rows=100000' },
      schemes_query = string.format('SELECT schema_name FROM `%s`.INFORMATION_SCHEMA.SCHEMATA', region),
      schemes_tables_query = string.format(
        'SELECT table_schema, table_name FROM `%s`.INFORMATION_SCHEMA.TABLES',
        region
      ),
      parse_results = function(results, min_len)
        return parse.results_parser(parse.vslice(results, 1), ',', min_len)
      end,
      layout_flag = '\\x',
      requires_stdin = true,
    }
  end,

  table_helpers = {
    List = 'select * from {optional_schema}{table} LIMIT 200',
    Columns = "select * from {schema}.INFORMATION_SCHEMA.COLUMNS where table_name='{table}'",
  },

  pagination = 'limit_offset',
}
