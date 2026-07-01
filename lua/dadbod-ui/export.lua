---@mod dadbod-ui.export  Orchestrate native CLI result export
---
--- The impure half of native export (`specs/native-export.md` §9 module 4): it
--- reads the query + connection off a `.dbout` result buffer, re-runs that query
--- through the adapter CLI in an export mode (native passthrough when the CLI can
--- emit the target format directly, else the canonical delimited extractor), and
--- writes the result to a file -- either verbatim (native) or via a pure Lua
--- formatter over the parsed `ExportData`.
---
--- Export runs the CLI directly through `vim.system` (DECISION-002): it does NOT
--- go through dadbod's `:DB` async job, so it never collides with a running query
--- and keeps the faithful delimited output rather than the aligned `.dbout` text.
---
--- The collaborators (the engine bridge, the process runner, the file writer, the
--- notifier) are injectable via the `deps` table so the whole flow is unit-tested
--- without a database -- the default seams call `bridge` / `vim.system` /
--- `writefile` / `notifications`.

local M = {}

--- Default async process runner: run `cmd` (argv) feeding `stdin`, invoking
--- `on_done(result)` on the main loop with a `vim.SystemCompleted`.
---@param cmd string[]
---@param stdin string|nil
---@param on_done fun(result: vim.SystemCompleted)
function M._run(cmd, stdin, on_done)
  vim.system(cmd, { text = true, stdin = stdin }, function(obj)
    vim.schedule(function()
      on_done(obj)
    end)
  end)
end

--- Default file writer: write `content` to `path`, normalizing to exactly one
--- trailing newline. A multi-line CSV field (embedded newline) is preserved
--- because the content is split into real lines before `writefile`. Returns
--- `ok, err`.
---@param path string
---@param content string
---@return boolean ok, string? err
function M._write(path, content)
  content = (content:gsub('\n$', ''))
  local lines = content == '' and {} or vim.split(content, '\n', { plain = true })
  local ok, res = pcall(vim.fn.writefile, lines, vim.fn.expand(path))
  if not ok then
    return false, tostring(res)
  end
  if res == -1 then
    return false, 'write failed'
  end
  return true
end

--- Serialize `data` to `fmt` via the matching pure formatter. `fmt` is one of the
--- `export_formats` function names (`csv`/`tsv`/`json`/`markdown`/`html`/`xml`/`sql`).
---@param data DadbodUI.ExportData
---@param fmt string
---@param opts? table  per-format options
---@return string
function M.format(data, fmt, opts)
  return require('dadbod-ui.export_formats')[fmt](data, opts)
end

--- The `{ url, scheme, query, source }` an export needs, recovered from a `.dbout`
--- result buffer: the resolved connection url (`b:db.db_url`), its adapter scheme,
--- the SQL that produced the result (the dadbod input temp file), and a table /
--- source name for JSON-wrap / SQL targets (`b:dbui_table_name`, else the input's
--- basename). Returns nil + an error string when the buffer isn't an export-able
--- result.
---@param bufnr integer
---@return { url: string, scheme: string, query: string, source: string }|nil, string?
function M.resolve_buffer(bufnr)
  local bridge = require('dadbod-ui.bridge')
  local db = vim.fn.getbufvar(bufnr, 'db')
  if type(db) ~= 'table' or type(db.db_url) ~= 'string' or db.db_url == '' then
    return nil, 'Not a query result buffer.'
  end
  local input = type(db.input) == 'string' and db.input or ''
  if input == '' or vim.fn.filereadable(input) ~= 1 then
    return nil, 'No stored query for this result.'
  end
  local query = table.concat(vim.fn.readfile(input), '\n')
  local table_name = vim.fn.getbufvar(bufnr, 'dbui_table_name')
  local source = (type(table_name) == 'string' and table_name ~= '') and table_name
    or (vim.fn.fnamemodify(input, ':t:r'))
  return {
    url = db.db_url,
    scheme = bridge.scheme_of(db.db_url),
    query = query,
    source = source,
  }
end

--- Build the export command: the adapter base argv plus the native-passthrough or
--- canonical-extract flags, with the query delivered on stdin or appended as the
--- final argv element per the adapter. Returns `{ cmd, stdin, native }`.
---@param params table  { url, scheme, format, query, prefer_native }
---@param bridge table  the engine bridge (injectable)
---@return { cmd: string[], stdin: string|nil, native: boolean }
local function build_command(params, bridge)
  local adapters = require('dadbod-ui.export_adapters')
  local native = adapters.is_native(params.scheme, params.format, params.prefer_native)
  local args = native and adapters.native_args(params.scheme, params.format) or adapters.extract_args(params.scheme)
  local cmd = bridge.command(params.url)
  vim.list_extend(cmd, args)
  local stdin
  if adapters.uses_stdin(params.scheme) then
    stdin = params.query
  else
    cmd[#cmd + 1] = params.query
  end
  return { cmd = cmd, stdin = stdin, native = native }
end

--- Export a result. `params` = { url, scheme, format, query, path, source?,
--- prefer_native?, format_opts? }. Re-runs the query through the CLI and writes
--- `path`. Native (CLI emits the format) -> stdout verbatim; otherwise parse the
--- canonical extract and run the Lua formatter. Notifies on success and on every
--- failure mode (unsupported adapter / format, CLI non-zero exit, write error).
--- Async; collaborators come from `deps` (defaulting to the real seams).
---@param params table
---@param deps? { bridge?: table, run?: function, write?: function, notify?: table }
---@return nil
function M.export(params, deps)
  deps = deps or {}
  local bridge = deps.bridge or require('dadbod-ui.bridge')
  local run = deps.run or M._run
  local write = deps.write or M._write
  local notify = deps.notify or require('dadbod-ui.notifications')
  local adapters = require('dadbod-ui.export_adapters')
  local extract = require('dadbod-ui.export_extract')

  local scheme, fmt = params.scheme, params.format
  if not adapters.supports(scheme) then
    return notify.error(string.format('Export is not supported for the %s adapter.', scheme))
  end
  if not vim.tbl_contains(adapters.formats_for(scheme), fmt) then
    return notify.error(string.format("Export format '%s' is not available for %s.", tostring(fmt), scheme))
  end

  local spec = build_command(params, bridge)
  run(spec.cmd, spec.stdin, function(result)
    if result == nil or result.code ~= 0 then
      local err = result and vim.trim(result.stderr or '') or ''
      local detail = err ~= '' and err or ('exit ' .. tostring(result and result.code))
      return notify.error('Export failed: ' .. detail)
    end
    local content, rows
    if spec.native then
      content = result.stdout or ''
    else
      local data = extract.parse(scheme, result.stdout or '')
      data.source = params.source
      rows = #data.rows
      content = M.format(data, fmt, params.format_opts)
    end
    local ok, werr = write(params.path, content)
    if not ok then
      return notify.error(string.format('Could not write %s: %s', params.path, tostring(werr)))
    end
    if spec.native then
      notify.info(string.format('Exported to %s', params.path))
    else
      notify.info(string.format('Exported %d row%s to %s', rows, rows == 1 and '' or 's', params.path))
    end
  end)
end

-- Interactive entry point ----------------------------------------------------

-- Display labels (mirroring DBeaver's target-format list) and file extensions
-- per format id. `format_item` shows the label; the file gets the extension.
local LABELS =
  { csv = 'CSV', tsv = 'TSV', json = 'JSON', markdown = 'Markdown', html = 'HTML', xml = 'XML', sql = 'SQL' }
local EXTENSIONS = { csv = 'csv', tsv = 'tsv', json = 'json', markdown = 'md', html = 'html', xml = 'xml', sql = 'sql' }

--- The default output path for `source` in `fmt`: `<cwd>/<source-or-export>.<ext>`.
---@param source string
---@param fmt string
---@return string
function M.default_path(source, fmt)
  local base = (source ~= nil and source ~= '') and source or 'export'
  return string.format('%s/%s.%s', vim.fn.getcwd(), base, EXTENSIONS[fmt] or fmt)
end

--- The resolved `export` config block (prefer_native + per-format opts), from the
--- session config unless `deps.config` overrides it. `{}` when unavailable.
---@param deps table
---@return table
local function export_config(deps)
  if deps.config ~= nil then
    return deps.config
  end
  local cfg = require('dadbod-ui.state').config()
  return type(cfg.export) == 'table' and cfg.export or {}
end

--- Drive an export from a `.dbout` result buffer interactively: recover the query
--- + connection, pick the target format (the DBeaver-style list, filtered to what
--- the adapter supports), prompt for the output path, then `export`. The picker /
--- prompt / notifier are injectable (`deps.select`, `deps.input`, `deps.notify`)
--- so the flow is testable without a UI. `prefer_native` and per-format options
--- come from the `export` config block.
---@param bufnr integer
---@param deps? table  { select?, input?, config?, bridge?, run?, write?, notify? }
---@return nil
function M.export_interactive(bufnr, deps)
  deps = deps or {}
  local select = deps.select or vim.ui.select
  local input = deps.input or vim.ui.input
  local notify = deps.notify or require('dadbod-ui.notifications')
  local adapters = require('dadbod-ui.export_adapters')

  local info, err = M.resolve_buffer(bufnr)
  if info == nil then
    return notify.error(err)
  end
  if not adapters.supports(info.scheme) then
    return notify.error(string.format('Export is not supported for the %s adapter.', info.scheme))
  end

  local cfg = export_config(deps)
  local prefer_native = cfg.prefer_native ~= false -- default true (DECISION-001)

  select(adapters.formats_for(info.scheme), {
    prompt = 'Export format:',
    format_item = function(fmt)
      return LABELS[fmt] or fmt
    end,
  }, function(fmt)
    if fmt == nil then
      return
    end
    input({ prompt = 'Export to: ', default = M.default_path(info.source, fmt), completion = 'file' }, function(path)
      if path == nil or vim.trim(path) == '' then
        return
      end
      M.export({
        url = info.url,
        scheme = info.scheme,
        format = fmt,
        query = info.query,
        path = vim.trim(path),
        source = info.source,
        prefer_native = prefer_native,
        format_opts = cfg[fmt],
      }, deps)
    end)
  end)
end

return M
