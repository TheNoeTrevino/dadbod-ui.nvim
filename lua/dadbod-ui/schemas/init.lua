-- Per-adapter schema/table introspection (SQL + parsers)
--
-- Each supported adapter carries the SQL that lists its schemas and its
-- (schema, table) pairs, plus a `parse_results` function that turns the raw
-- command output into either a list of names (`min_len == 1`) or a list of
-- `{ schema, table }` rows (`min_len == 2`). The queries and the
-- slicing/splitting rules encode each CLI's exact output framing (header rows,
-- footer counts, column delimiters) and must not be paraphrased.
--
-- Execution is async everywhere: every feature query (schema/table listing,
-- routines, the dbout foreign-key lookup) builds a `DadbodUI.CommandSpec` via
-- `command_spec` and runs through `bridge.run_many`, so no introspection ever
-- freezes the UI. The command construction still goes through dadbod (via
-- `bridge.command`) so the per-adapter argv stays correct.

---@class DadbodUI.SchemasModule
---@field results_parser fun(results: string[], delimiter: string, min_len: integer): any[]
---@field get fun(scheme: string, config?: DadbodUI.Config): DadbodUI.SchemaAdapter
---@field supports_schemes fun(scheme_info: DadbodUI.SchemaAdapter, parsed_url: DadbodUI.ParsedUrl): boolean
---@field command_spec fun(conn: string, scheme_info: DadbodUI.SchemaAdapter, query: string): DadbodUI.CommandSpec
---@field result_lines fun(result: { code: integer, stdout: string, stderr: string }): string[]
---@field normalize_table_list fun(scheme: string, raw: string[]): string[]

---@private
local adapters = require('dadbod-ui.adapters')
---@private
local bridge = require('dadbod-ui.bridge')
---@private
local parse = require('dadbod-ui.schemas.parse')

---@type DadbodUI.SchemasModule
---@diagnostic disable-next-line: missing-fields
local M = {}

M.results_parser = parse.results_parser

--- The metadata for `scheme` (built by its adapter's `schema` field), or an
--- empty table for a scheme we don't know. Note this is NOT the same as "no
--- schema support": sqlite returns a non-empty table carrying only
--- dbout-navigation fields (no `schemes_query`), so it has metadata without
--- schema support. `config` tunes the queries that depend on options
--- (`use_postgres_views`, `is_oracle_legacy`).
---@param scheme string  raw url scheme
---@param config? DadbodUI.Config
---@return DadbodUI.SchemaAdapter
function M.get(scheme, config)
  local spec = adapters.get(scheme)
  if spec == nil or spec.schema == nil then
    return {}
  end
  return spec.schema(config)
end

--- Whether the adapter exposes schemas for this url: schema support requires a
--- `schemes_query`, and adapters flagged `db_path_lists_tables` (mysql/mariadb)
--- list tables directly when the url names a database in its path.
---@param scheme_info DadbodUI.SchemaAdapter
---@param parsed_url DadbodUI.ParsedUrl
---@return boolean
function M.supports_schemes(scheme_info, parsed_url)
  if scheme_info == nil or scheme_info.schemes_query == nil or scheme_info.schemes_query == '' then
    return false
  end
  local spec = adapters.get(parsed_url.scheme)
  if spec ~= nil and spec.db_path_lists_tables and (parsed_url.path or '') ~= '/' then
    return false
  end
  return true
end

--- Build the command spec for running `query` against `conn` with this adapter.
--- dadbod constructs the base argv for the adapter's `callable` (interactive by
--- default), the adapter's extra `args` are appended, and the query is either fed
--- on stdin (`requires_stdin`) or appended as the final argument.
---@param conn string  resolved connection url
---@param scheme_info DadbodUI.SchemaAdapter
---@param query string
---@return DadbodUI.CommandSpec
function M.command_spec(conn, scheme_info, query)
  local callable = scheme_info.callable or 'interactive'
  local cmd = bridge.command(conn, callable)
  if scheme_info.args then
    vim.list_extend(cmd, scheme_info.args)
  end
  if scheme_info.requires_stdin then
    return { cmd = cmd, stdin = query }
  end
  cmd[#cmd + 1] = query
  return { cmd = cmd }
end

--- Turn one `vim.system` result into the line list dadbod's `db#systemlist`
--- would have returned: empty on a non-zero exit, otherwise stdout split into
--- lines with trailing CR stripped and the single trailing blank line (from the
--- final newline) dropped. Only ONE trailing blank is dropped -- matching
--- systemlist exactly -- because adapters with a fixed-tail slice (e.g.
--- sqlserver's `[0:-3]`) are calibrated to that framing.
---@param result { code: integer, stdout: string, stderr: string }
---@return string[]
function M.result_lines(result)
  if result == nil or result.code ~= 0 then
    return {}
  end
  local lines = vim.split(result.stdout or '', '\n')
  for i, line in ipairs(lines) do
    lines[i] = (line:gsub('\r$', ''))
  end
  if #lines > 0 and lines[#lines] == '' then
    lines[#lines] = nil
  end
  return lines
end

--- Normalize the raw table list dadbod's `tables` adapter call returns for a
--- non-schema adapter, via the adapter's `normalize_tables` (sqlite splits
--- space-separated chunks, mysql filters header/warning lines). Identity for
--- adapters without one.
---@param scheme string
---@param raw string[]
---@return string[]
function M.normalize_table_list(scheme, raw)
  local spec = adapters.get(scheme)
  if spec == nil or spec.normalize_tables == nil then
    return raw
  end
  return spec.normalize_tables(raw)
end

return M
