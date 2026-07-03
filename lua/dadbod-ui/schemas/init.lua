-- Per-adapter schema/table introspection (SQL + parsers)
--
-- Each supported adapter carries the SQL that lists its schemas and its
-- (schema, table) pairs, plus a `parse_results` function that turns the raw
-- command output into either a list of names (`min_len == 1`) or a list of
-- `{ schema, table }` rows (`min_len == 2`). The queries and the
-- slicing/splitting rules encode each CLI's exact output framing (header rows,
-- footer counts, column delimiters) and must not be paraphrased.
--
-- Execution is async: instead of dadbod's blocking `db#systemlist`, the drawer
-- builds a `DadbodUI.CommandSpec` via `command_spec` and runs schema + table
-- listing concurrently through `bridge.run_many`, so a large database never
-- freezes the UI on expand. The command construction still goes through dadbod
-- (via `bridge.command`) so the per-adapter argv stays correct.

---@class DadbodUI.SchemasModule
---@field results_parser fun(results: string[], delimiter: string, min_len: integer): any[]
---@field get fun(scheme: string, config?: DadbodUI.Config): DadbodUI.SchemaAdapter
---@field supports_schemes fun(scheme_info: DadbodUI.SchemaAdapter, parsed_url: DadbodUI.ParsedUrl): boolean
---@field command_spec fun(conn: string, scheme_info: DadbodUI.SchemaAdapter, query: string): DadbodUI.CommandSpec
---@field query fun(conn: string, scheme_info: DadbodUI.SchemaAdapter, query: string): string[]
---@field result_lines fun(result: { code: integer, stdout: string, stderr: string }): string[]
---@field normalize_table_list fun(scheme: string, raw: string[]): string[]

---@private
local bridge = require('dadbod-ui.bridge')
---@private
local parse = require('dadbod-ui.schemas.parse')

---@type DadbodUI.SchemasModule
---@diagnostic disable-next-line: missing-fields
local M = {}

M.results_parser = parse.results_parser

---@private
-- scheme -> builder. Postgres aliases share one builder. sqlite's entry carries
-- ONLY dbout-navigation metadata (no schemes_query), so it keeps the tables-only
-- drawer path while still supporting the foreign-key jump + cell/header nav.
local builders = {
  postgres = require('dadbod-ui.schemas.postgres'),
  postgresql = require('dadbod-ui.schemas.postgres'),
  sqlserver = require('dadbod-ui.schemas.sqlserver'),
  mysql = require('dadbod-ui.schemas.mysql'),
  mariadb = require('dadbod-ui.schemas.mysql'),
  oracle = require('dadbod-ui.schemas.oracle'),
  bigquery = require('dadbod-ui.schemas.bigquery'),
  sqlite = require('dadbod-ui.schemas.sqlite'),
  sqlite3 = require('dadbod-ui.schemas.sqlite'),
  clickhouse = require('dadbod-ui.schemas.clickhouse'),
}

--- The metadata for `scheme`, or an empty table for a scheme we don't know.
--- Note this is NOT the same as "no schema support": sqlite returns a non-empty
--- table carrying only dbout-navigation fields (no `schemes_query`), so it has
--- metadata without schema support. `config` tunes the queries that depend on
--- options (`use_postgres_views`, `is_oracle_legacy`).
---@param scheme string  raw url scheme
---@param config? DadbodUI.Config
---@return DadbodUI.SchemaAdapter
function M.get(scheme, config)
  local builder = builders[scheme]
  if builder == nil then
    return {}
  end
  return builder(config)
end

--- Whether the adapter exposes schemas for this url: schema support requires a
--- `schemes_query`, and MySQL/MariaDB urls that name a database in the path list
--- tables directly instead.
---@param scheme_info DadbodUI.SchemaAdapter
---@param parsed_url DadbodUI.ParsedUrl
---@return boolean
function M.supports_schemes(scheme_info, parsed_url)
  if scheme_info == nil or scheme_info.schemes_query == nil or scheme_info.schemes_query == '' then
    return false
  end
  local scheme_name = (parsed_url.scheme or ''):lower()
  if (scheme_name == 'mysql' or scheme_name == 'mariadb') and (parsed_url.path or '') ~= '/' then
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

--- Run `query` against `conn` synchronously and return its output lines (trailing
--- CR stripped). Blocks Neovim, so it is reserved for the single small
--- introspection lookup the dbout foreign-key jump needs -- not for the drawer's
--- bulk introspection, which fans out async via `run_many`. Goes through the
--- bridge (the engine boundary) for the actual call.
---@param conn string  resolved connection url
---@param scheme_info DadbodUI.SchemaAdapter
---@param query string
---@return string[]
function M.query(conn, scheme_info, query)
  local spec = M.command_spec(conn, scheme_info, query)
  local result = bridge.systemlist(spec.cmd, spec.stdin)
  return vim.tbl_map(function(line)
    return (line:gsub('\r$', ''))
  end, result)
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
--- non-schema adapter: sqlite lists tables as space-separated strings (split and
--- sort), mysql prepends a header / warning lines (filter them out).
---@param scheme string
---@param raw string[]
---@return string[]
function M.normalize_table_list(scheme, raw)
  local lower = scheme:lower()
  if lower:match('^sqlite') then
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
  end
  if lower:match('^mysql') then
    return vim.tbl_filter(function(name)
      -- Anchored to the START of the name: an unanchored `Tables_in_` would also
      -- drop any real table whose name merely CONTAINS that substring.
      return not name:match('mysql: %[Warning%]') and not name:match('^Tables_in')
    end, raw)
  end
  return raw
end

return M
