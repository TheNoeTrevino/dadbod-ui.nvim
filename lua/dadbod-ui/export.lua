-- Orchestrate native CLI result export
--
-- The impure half of native export (`specs/native-export.md` §9 module 4): it
-- reads the query + connection off a `.dbout` result buffer, re-runs that query
-- through the adapter CLI in an export mode (native passthrough when the CLI can
-- emit the target format directly, else the canonical delimited extractor), and
-- writes the result to a file -- either verbatim (native) or via a pure Lua
-- formatter over the parsed `ExportData`.
--
-- Export runs the CLI directly through `vim.system` (DECISION-002): it does NOT
-- go through dadbod's `:DB` async job, so it never collides with a running query
-- and keeps the faithful delimited output rather than the aligned `.dbout` text.
--
-- The collaborators (the engine bridge, the process runner, the file writer, the
-- notifier) are injectable via the `deps` table so the whole flow is unit-tested
-- without a database -- the default seams call `bridge` / `vim.system` /
-- `writefile` / `notifications`.

---@alias DadbodUI.ExportRunOnDone fun(result: DadbodUI.SystemCompleted)
---@alias DadbodUI.ExportTransformCallback fun(ok: boolean, content: string?, rows: integer?, err: string?)
---@alias DadbodUI.ExportTransform fun(scheme: string, stdout: string, fmt: string, opts: table, source: string, cb: DadbodUI.ExportTransformCallback)
--- A progress backend: `start` shows a spinner for the format and returns a
--- token; `stop` tears it down for that token.
---@class DadbodUI.ExportProgress
---@field start fun(fmt: string): integer
---@field stop fun(token: integer)
---@alias DadbodUI.ExportBufferInfo { url: string, scheme: string, query: string, source: string, page: DadbodUI.PageState? }

--- The injectable collaborators for `export` / `export_interactive`; every field
--- defaults to the real seam when absent.
---@class DadbodUI.ExportDeps
---@field bridge? table  the engine bridge
---@field run? fun(cmd: string[], stdin: string|nil, on_done: DadbodUI.ExportRunOnDone)
---@field write? fun(path: string, content: string): boolean, string?
---@field notify? table
---@field transform? DadbodUI.ExportTransform
---@field progress? DadbodUI.ExportProgress
---@field config? table  the resolved `export` config block
---@field select? function
---@field input? function
---@field confirm? fun(msg: string): boolean

---@class DadbodUI.ExportModule
---@field _run fun(cmd: string[], stdin: string|nil, on_done: DadbodUI.ExportRunOnDone)  test seam: async process runner
---@field _write fun(path: string, content: string): boolean, string?  test seam: file writer
---@field format fun(data: DadbodUI.ExportData, fmt: string, opts?: table): string
---@field _transform_sync fun(scheme: string, stdout: string, fmt: string, opts: table, source: string): string, integer  test seam: inline parse+format core
---@field _TRANSFORM_THRESHOLD integer  test seam: bytes below which the transform runs inline
---@field _transform_async DadbodUI.ExportTransform  test seam: worker-thread parse+format
---@field resolve_buffer fun(bufnr: integer): DadbodUI.ExportBufferInfo|nil, string?
---@field query_for fun(info: table, page_choice?: 'full'|'current'): string
---@field export fun(params: table, deps?: DadbodUI.ExportDeps)
---@field _dbout_progress fun(bufnr: integer): DadbodUI.ExportProgress|nil  test seam: default winbar progress backend
---@field default_path fun(source: string, fmt: string, dir?: string): string
---@field format_opts fun(cfg: table, fmt: string, quote: boolean): table
---@field export_prompt fun(info: { url: string, scheme: string, query: string, source?: string }, deps?: DadbodUI.ExportDeps)
---@field export_interactive fun(bufnr: integer, deps?: DadbodUI.ExportDeps, page_choice?: 'full'|'current')

---@type DadbodUI.ExportModule
---@diagnostic disable-next-line: missing-fields
local M = {}

--- Default async process runner: run `cmd` (argv) feeding `stdin`, invoking
--- `on_done(result)` on the main loop with a `DadbodUI.SystemCompleted`.
---@param cmd string[]
---@param stdin string|nil
---@param on_done DadbodUI.ExportRunOnDone
function M._run(cmd, stdin, on_done)
  vim.system(cmd, { text = true, stdin = stdin }, function(obj)
    vim.schedule(function()
      on_done(obj)
    end)
  end)
end

--- Default file writer: write `content` to `path`, normalizing to exactly one
--- trailing newline. Writes the raw bytes in one shot via `io.open` in binary
--- mode -- NOT `writefile`, which turns a newline inside a list item into a NUL
--- (so a multi-line CSV field would be corrupted) and forces an O(rows) `vim.split`
--- over the whole payload on the main thread (the export "freeze" for a large
--- result). A single binary write preserves embedded newlines verbatim and costs
--- one C call. Returns `ok, err`.
---@param path string
---@param content string
---@return boolean ok, string? err
function M._write(path, content)
  content = (content:gsub('\n$', ''))
  local data = content == '' and '' or (content .. '\n')
  local fh, oerr = io.open(vim.fs.normalize(path), 'wb')
  if fh == nil then
    return false, oerr or 'could not open file'
  end
  local ok, werr = fh:write(data)
  fh:close()
  if not ok then
    return false, tostring(werr)
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

---@private
-- The `.../lua` directory this plugin lives under, derived from THIS file's path
-- (`.../lua/dadbod-ui/export.lua` -> `.../lua`). Passed into the worker thread so
-- it can `require` the (vim-free) extractor / formatter with no runtimepath.
---@return string
local function lua_dir()
  local this = debug.getinfo(1, 'S').source:gsub('^@', '')
  return vim.fn.fnamemodify(this, ':h:h')
end

---@private
-- Serialize a flat table of scalar `opts` (strings / numbers / booleans) to a Lua
-- source literal, so it can be handed to the worker thread as a string and rebuilt
-- there with `loadstring`. Only the value kinds the format-opts tables actually
-- hold are supported; anything else is dropped.
---@param opts? table
---@return string
local function serialize_opts(opts)
  local parts = {}
  for k, v in pairs(opts or {}) do
    local t = type(v)
    local val
    if t == 'string' then
      val = string.format('%q', v)
    elseif t == 'number' or t == 'boolean' then
      val = tostring(v)
    end
    if val ~= nil then
      parts[#parts + 1] = string.format('[%q]=%s', k, val)
    end
  end
  return 'return {' .. table.concat(parts, ',') .. '}'
end

--- Parse `stdout` for `scheme` and format it as `fmt` INLINE (on the caller's
--- thread). Returns `(content, rows)`. The synchronous core shared by the async
--- transform's small-payload / no-thread fast path and by the specs.
---@param scheme string
---@param stdout string
---@param fmt string
---@param opts table
---@param source string
---@return string content, integer rows
function M._transform_sync(scheme, stdout, fmt, opts, source)
  local data = require('dadbod-ui.export_extract').parse(scheme, stdout or '')
  -- Normalize '' to nil: an empty string is truthy in Lua, so `data.source` would
  -- otherwise defeat the `opts.table or data.source or 'exported_table'` fallback
  -- chain in the SQL formatter (and wrap the JSON export under an empty key).
  data.source = require('dadbod-ui.export_formats').nonempty(source)
  return M.format(data, fmt, opts), #data.rows
end

-- Below this many bytes of CLI output, the parse+format is cheap enough to run
-- inline -- the thread hop would cost more than the work, and the main loop won't
-- stall. Above it, the transform is offloaded to a worker thread.
M._TRANSFORM_THRESHOLD = 64 * 1024

--- Parse + format `stdout` and deliver the result to `cb(ok, content, rows, err)`.
--- A large payload runs in a `vim.uv` worker thread (pure Lua, no `vim` API) so
--- the export never blocks the UI; a small payload (or a build without
--- `uv.new_work`) runs inline. `cb` always fires on the main loop.
---@param scheme string
---@param stdout string
---@param fmt string
---@param opts table
---@param source string
---@param cb DadbodUI.ExportTransformCallback
---@return nil
function M._transform_async(scheme, stdout, fmt, opts, source, cb)
  stdout = stdout or ''
  -- Map a `pcall`/worker `(ok, content_or_err, rows)` triple onto `cb`'s
  -- `(ok, content?, rows?, err?)` shape -- shared by the inline fast path and the
  -- worker completion so the arity lives in one place.
  local function deliver(ok, content, rows)
    if ok then
      cb(true, content, rows)
    else
      cb(false, nil, nil, tostring(content))
    end
  end
  local uv = vim.uv
  if #stdout < M._TRANSFORM_THRESHOLD or type(uv.new_work) ~= 'function' then
    return deliver(pcall(M._transform_sync, scheme, stdout, fmt, opts, source or ''))
  end
  local work = uv.new_work(
    -- Thread body: NO `vim` global here. Point `package.path` at the plugin's lua
    -- dir, then require the vim-free extractor + formatter and run the transform.
    function(dir, scheme_, text, fmt_, opts_src, source_)
      package.path = dir .. '/?.lua;' .. dir .. '/?/init.lua;' .. package.path
      local ok, content, rows = pcall(function()
        local extract = require('dadbod-ui.export_extract')
        local formats = require('dadbod-ui.export_formats')
        local o = (loadstring or load)(opts_src)()
        local data = extract.parse(scheme_, text)
        -- Same '' -> nil normalization as `_transform_sync` (the empty string
        -- crossed the thread boundary as the nil carrier -- see `work:queue` below).
        data.source = formats.nonempty(source_)
        return formats[fmt_](data, o), #data.rows
      end)
      if ok then
        return true, content, rows
      end
      return false, content -- `content` holds the pcall error message here
    end,
    -- Completion: `uv.new_work`'s after-callback runs in a FAST event context,
    -- where the vim API (the writer's `expand`, the notifier, the winbar spinner)
    -- is off-limits -- so hop to the main loop before invoking `cb`.
    function(ok, content, rows)
      vim.schedule(function()
        if ok then
          cb(true, content, rows)
        else
          cb(false, nil, nil, tostring(content))
        end
      end)
    end
  )
  work:queue(lua_dir(), scheme, stdout, fmt, serialize_opts(opts), source or '')
end

---@private
--- A usable table/source name derived from `query`: the first identifier after a
--- `FROM` (quoting / schema-qualifier stripped to its last segment), else
--- `results`. Used for the JSON-wrap key, the SQL `INSERT` target, and the default
--- export filename when the buffer carries no explicit table name.
---@param query string
---@return string
local function derive_source(query)
  -- word-boundary, case-insensitive FROM, optional opening quote/bracket, then the identifier.
  -- The leading frontier includes `_` in its word-char set (`%f[%w_]`, not the
  -- plain `%f[%w]` Lua's `%w` lacks underscore for) so `a_from FROM t` doesn't
  -- match the trailing "from" inside the identifier `a_from` -- `_` -> `f` is not
  -- a boundary once `_` counts as a word char.
  local ident = query:match('%f[%w_][Ff][Rr][Oo][Mm]%s+["`%[]?([%w_%.]+)')
  if ident then
    local name = ident:match('([%w_]+)$') -- last dotted segment (drops schema.)
    if name and name ~= '' then
      return name
    end
  end
  return 'results'
end

--- The `{ url, scheme, query, source, page }` an export needs, recovered from a
--- `.dbout` result buffer: the resolved connection url (`b:db.db_url`), its adapter
--- scheme, the SQL that produced the on-screen result (the dadbod input temp file --
--- for a paginated result this is the *paged* SQL), a table / source name for
--- JSON-wrap / SQL targets (`b:dbui_table_name`, else the input's basename), and the
--- pagination state (`b:dbui_page`) when the result is paged. Returns nil + an error
--- string when the buffer isn't an export-able result.
---@param bufnr integer
---@return DadbodUI.ExportBufferInfo|nil, string?
function M.resolve_buffer(bufnr)
  local bridge = require('dadbod-ui.bridge')
  local utils = require('dadbod-ui.utils')
  local db = vim.b[bufnr].db
  if type(db) ~= 'table' or type(db.db_url) ~= 'string' or db.db_url == '' then
    return nil, 'Not a query result buffer.'
  end
  local input = type(db.input) == 'string' and db.input or ''
  if input == '' or not utils.is_file(input) then
    return nil, 'No stored query for this result.'
  end
  local query = table.concat(vim.fn.readfile(input), '\n')
  -- The dbout (result) buffer does not carry `b:dbui_table_name` (that lives on the
  -- query buffer) and its input file is a tempname, so the basename would be junk
  -- like `0`. Read the table name if it is somehow present, else derive one from
  -- the query (the first identifier after FROM, else `results`).
  local table_name = vim.b[bufnr].dbui_table_name
  local source = (type(table_name) == 'string' and table_name ~= '') and table_name or derive_source(query)
  local page = vim.b[bufnr].dbui_page
  return {
    url = db.db_url,
    scheme = bridge.scheme_of(db.db_url),
    query = query,
    source = source,
    page = type(page) == 'table' and page or nil,
  }
end

--- The SQL to export for `info`, per the page choice (DECISION-003): `'full'`
--- (default) exports the whole un-paginated query -- for a paged result that is
--- `info.page.original_sql`, not the on-screen page. `'current'` exports only the
--- on-screen page (`info.query`, already the paged SQL). A non-paginated result
--- ignores the choice -- its stored query is the whole result either way.
---@param info table  a resolve_buffer result
---@param page_choice? 'full'|'current'
---@return string
function M.query_for(info, page_choice)
  if info.page ~= nil and page_choice ~= 'current' then
    return info.page.original_sql
  end
  return info.query
end

---@private
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
---@param deps? DadbodUI.ExportDeps
---@return nil
function M.export(params, deps)
  deps = deps or {}
  local bridge = deps.bridge or require('dadbod-ui.bridge')
  local run = deps.run or M._run
  local write = deps.write or M._write
  local notify = deps.notify or require('dadbod-ui.notifications')
  -- The parse+format step, injectable; defaults to the worker-thread transform
  -- (off the main loop for large results). Small results run inline inside it.
  local transform = deps.transform or M._transform_async
  local adapters = require('dadbod-ui.export_adapters')

  local scheme, fmt = params.scheme, params.format
  if not adapters.supports(scheme) then
    return notify.error(string.format('Export is not supported for the %s adapter.', scheme))
  end
  if not vim.tbl_contains(adapters.formats_for(scheme), fmt) then
    return notify.error(string.format("Export format '%s' is not available for %s.", tostring(fmt), scheme))
  end

  -- Progress feedback (optional): a spinner segment on the result winbar while the
  -- CLI runs and the file is written. Injectable so the orchestrator stays
  -- UI-free; the interactive entry point wires the dbout-backed one (bound to the
  -- result buffer). Independent per call, so concurrent exports each animate.
  local progress = deps.progress
  local token = progress and progress.start(fmt) or nil
  -- Tear the spinner down exactly once, guarded, on every terminal outcome.
  local function stop_progress()
    if progress then
      progress.stop(token)
    end
  end

  local spec = build_command(params, bridge)
  ---@param result DadbodUI.SystemCompleted|nil
  run(spec.cmd, spec.stdin, function(result)
    if result == nil or result.code ~= 0 then
      stop_progress()
      local err = result and vim.trim(result.stderr or '') or ''
      local detail = err ~= '' and err or ('exit ' .. tostring(result and result.code))
      return notify.error('Export failed: ' .. detail)
    end
    -- Land the file and notify -- shared by the native and formatter paths.
    -- `rows == nil` => native passthrough (byte count unknown, generic message);
    -- a number => the formatter counted rows.
    local function finish(content, rows)
      local ok, werr = write(params.path, content)
      stop_progress()
      if not ok then
        return notify.error(string.format('Could not write %s: %s', params.path, tostring(werr)))
      end
      if rows == nil then
        notify.info(string.format('Exported to %s', params.path))
      else
        notify.info(string.format('Exported %d row%s to %s', rows, rows == 1 and '' or 's', params.path))
      end
    end

    if spec.native then
      local content = result.stdout or ''
      -- `sqlite3 -json` (the only native JSON path) emits nothing for a zero-row
      -- result; keep the file valid JSON rather than writing an empty file.
      if fmt == 'json' and vim.trim(content) == '' then
        content = '[]'
      end
      return finish(content, nil)
    end

    -- Formatter path: parse the canonical extract, run the Lua formatter. This is
    -- CPU-bound pure Lua, so a large result is transformed OFF the main loop
    -- (a vim.uv worker) -- the export no longer freezes the UI, and the winbar
    -- spinner keeps animating. Small results run inline (see `_transform_async`).
    transform(scheme, result.stdout or '', fmt, params.format_opts, params.source, function(ok, content, rows, terr)
      if not ok then
        stop_progress()
        return notify.error('Export failed: ' .. tostring(terr))
      end
      finish(content, rows)
    end)
  end)
end

--- The default progress backend for an export driven from result buffer `bufnr`:
--- a dbout-backed winbar spinner. Returns nil when dbout can't be loaded or the
--- bufnr is not usable, so `M.export` simply runs without a spinner. Lazy require
--- keeps export <-> dbout free of a load-time cycle.
---@param bufnr integer
---@return DadbodUI.ExportProgress|nil
function M._dbout_progress(bufnr)
  local ok, dbout = pcall(require, 'dadbod-ui.dbout')
  if not ok or type(bufnr) ~= 'number' then
    return nil
  end
  return {
    start = function(fmt)
      return dbout.export_start(bufnr, fmt)
    end,
    stop = function(token)
      return dbout.export_stop(bufnr, token)
    end,
  }
end

-- Interactive entry point ----------------------------------------------------

---@private
-- Display labels and file extensions per format id. `format_item` shows the
-- label; the file gets the extension.
local LABELS =
  { csv = 'CSV', tsv = 'TSV', json = 'JSON', markdown = 'Markdown', html = 'HTML', xml = 'XML', sql = 'SQL' }
---@private
local EXTENSIONS = { csv = 'csv', tsv = 'tsv', json = 'json', markdown = 'md', html = 'html', xml = 'xml', sql = 'sql' }

--- The default output path for `source` in `fmt`: `<dir>/<source-or-export>.<ext>`,
--- where `dir` is the configured `export.default_path` directory when non-empty,
--- else the current working directory.
---@param source string
---@param fmt string
---@param dir? string  configured default directory ('' / nil => cwd)
---@return string
function M.default_path(source, fmt, dir)
  local base = require('dadbod-ui.export_formats').nonempty(source) or 'export'
  local base_dir = (dir ~= nil and dir ~= '') and vim.fs.normalize(dir) or vim.fn.getcwd()
  return string.format('%s/%s.%s', base_dir, base, EXTENSIONS[fmt] or fmt)
end

--- The per-format options handed to a formatter: the format's own config
--- sub-table merged with the top-level `coerce_numbers` (which lives outside the
--- per-format tables, so it must be folded in here), plus `quote_identifiers` for
--- SQL from the adapter's resolved `quote` flag (postgres quotes identifiers;
--- mysql / sqlite do not). Takes the boolean, not a scheme: the quote fact is
--- resolved once (`entry.quote`, or `schemas.get(scheme, config)` on the dbout
--- path) rather than re-derived here by re-running the adapter's schema builder.
---@param cfg table  the resolved `export` config block
---@param fmt string
---@param quote boolean  whether the adapter quotes identifiers
---@return table
function M.format_opts(cfg, fmt, quote)
  local opts = vim.tbl_extend('force', { coerce_numbers = cfg.coerce_numbers }, cfg[fmt] or {})
  if fmt == 'sql' then
    opts.quote_identifiers = quote == true
  end
  return opts
end

---@private
--- The resolved `export` config block (prefer_native + per-format opts), from the
--- session config unless `deps.config` overrides it. `{}` when unavailable.
---@param deps DadbodUI.ExportDeps
---@return table
local function export_config(deps)
  if deps.config ~= nil then
    return deps.config
  end
  local cfg = require('dadbod-ui.state').config()
  return type(cfg.results.export) == 'table' and cfg.results.export or {}
end

--- Prompt for a target format + output path for `info` and export -- the shared
--- interactive core. Both entry points resolve their own `info` and hand it here:
--- the `.dbout` result buffer (`export_interactive`) and the query buffer
--- (`db_ui`'s `explain`-style `export_query`). Picks the target format (the
--- list of formats the adapter supports), prompts for the
--- output path (guarding an existing file), then `export`s the query RESULTS.
--- The picker / prompt / notifier / confirm are injectable (`deps.select`,
--- `deps.input`, `deps.notify`, `deps.confirm`) so the flow is testable without a
--- UI. `prefer_native` and per-format options come from the `export` config
--- block. `info.source` (the output-filename base) defaults to a name derived from
--- the query when absent. `deps.progress`, when set, animates a spinner.
---@param info { url: string, scheme: string, query: string, source?: string }
---@param deps? DadbodUI.ExportDeps  { select?, input?, confirm?, config?, bridge?, run?, write?, notify?, progress? }
---@return nil
function M.export_prompt(info, deps)
  deps = deps or {}
  local select = deps.select or vim.ui.select
  local input = deps.input or vim.ui.input
  local notify = deps.notify or require('dadbod-ui.notifications')
  -- Overwrite guard (injectable): default to a blocking yes/no so an existing file
  -- is never clobbered silently. Returns true to proceed.
  local confirm = deps.confirm or function(msg)
    return vim.fn.confirm(msg, '&Yes\n&No', 2) == 1
  end
  local adapters = require('dadbod-ui.export_adapters')
  if not adapters.supports(info.scheme) then
    return notify.error(string.format('Export is not supported for the %s adapter.', info.scheme))
  end

  local cfg = export_config(deps)
  local prefer_native = cfg.prefer_native ~= false -- default true (DECISION-001)
  local source = (type(info.source) == 'string' and info.source ~= '') and info.source or derive_source(info.query)

  select(adapters.formats_for(info.scheme), {
    prompt = 'Export format:',
    format_item = function(fmt)
      return LABELS[fmt] or fmt
    end,
  }, function(fmt)
    if fmt == nil then
      return
    end
    local default = M.default_path(source, fmt, cfg.default_path)
    input({ prompt = 'Export to: ', default = default, completion = 'file' }, function(path)
      if path == nil or vim.trim(path) == '' then
        return
      end
      path = vim.trim(path)
      if
        require('dadbod-ui.utils').is_file(vim.fs.normalize(path))
        and not confirm(string.format('%s exists. Overwrite?', path))
      then
        return notify.info('Export cancelled.')
      end
      M.export({
        url = info.url,
        scheme = info.scheme,
        format = fmt,
        query = info.query,
        path = path,
        source = source,
        prefer_native = prefer_native,
        -- The dbout path has no connection entry, only the scheme: resolve the
        -- quote flag with the session config (never a config-less schema build).
        format_opts = M.format_opts(
          cfg,
          fmt,
          require('dadbod-ui.schemas').get(info.scheme, require('dadbod-ui.state').config()).quote == true
        ),
      }, deps)
    end)
  end)
end

--- Drive an export from a `.dbout` result buffer interactively: recover the query
--- + connection from the result buffer, then hand off to `export_prompt`. Refuses
--- a second export while one is already running (the spinner stays on the result
--- winbar meanwhile). `page_choice` selects whole-query vs on-screen-page rows.
---@param bufnr integer
---@param deps? DadbodUI.ExportDeps  { select?, input?, config?, bridge?, run?, write?, notify? }
---@param page_choice? 'full'|'current'  which rows to export (DECISION-003); default 'full'
---@return nil
function M.export_interactive(bufnr, deps, page_choice)
  deps = deps or {}
  local notify = deps.notify or require('dadbod-ui.notifications')
  local info, err = M.resolve_buffer(bufnr)
  if info == nil then
    return notify.error(err)
  end
  -- One export at a time: refuse a second while one is running (the spinner stays
  -- visible on the result winbar meanwhile). Querying is not blocked.
  local dbout_ok, dbout = pcall(require, 'dadbod-ui.dbout')
  if deps.progress == nil and dbout_ok and dbout.export_in_progress() then
    return notify.error('An export is already in progress. Please wait for it to finish.')
  end
  -- Show the winbar export spinner on THIS result buffer unless the caller injected
  -- its own progress backend (specs pass none). Extend a copy rather than mutating
  -- the caller-owned `deps`.
  local call_deps = vim.tbl_extend('force', deps, { progress = deps.progress or M._dbout_progress(bufnr) })
  M.export_prompt({
    url = info.url,
    scheme = info.scheme,
    query = M.query_for(info, page_choice),
    source = info.source,
  }, call_deps)
end

return M
