-- Thin pass-through over vim-dadbod (the query engine)
--
-- This module is the ONLY place in the port that talks to vim-dadbod. Every
-- function is a thin wrapper over dadbod's vimscript API (`db#*`) and the `:DB`
-- command. The Lua port keeps dadbod as the engine and owns only the UI, so
-- this file is the engine boundary -- keep it small and faithful.
--
-- vim-dadbod exposes TWO execution paths and we mirror both:
--
--   * Synchronous  -> `systemlist()`. Blocks Neovim. Used for fast schema /
--                     table introspection that populates the drawer.
--   * Asynchronous -> `execute()` via `:DB`. Non-blocking: dadbod spawns a job,
--                     writes a `.dbout` file and fires the User autocmds
--                     `*DBExecutePre` / `*DBExecutePost`. Subscribe with
--                     `on_pre` / `on_post` to drive the in-buffer loading
--                     indicator and the result rendering.
--
-- Scheme resolution note: `db#url#parse` returns the RAW scheme (`postgres`,
-- not `postgresql`), but no adapter is ever dispatched on a raw scheme here.
-- `db#resolve` canonicalizes the scheme via `g:db_adapters` (e.g.
-- `postgres`->`postgresql`, `sqlite3`->`sqlite`) before dispatch, dadbod ships
-- the canonical adapter files (`postgresql.vim`, `sqlite.vim`), and every
-- adapter call in this module resolves the URL first. So no scheme-alias
-- globals (`g:db_adapter_<scheme>`) are needed -- and deliberately NOT setting
-- them keeps `db#adapter#schemes()` canonical: it enumerates `g:db_adapter_*`
-- keys, so aliases would inject phantom non-canonical entries (`postgres`,
-- `sqlite3`) alongside the real ones.

---@alias DadbodUI.SystemCompleted { code: integer, signal: integer, stdout?: string, stderr?: string }
---@alias DadbodUI.ConnectAsyncCallback fun(ok: boolean, conn: string)
---@alias DadbodUI.RunManyCallback fun(results: DadbodUI.SystemCompleted[])
---@alias DadbodUI.ExecuteEventCallback fun(info: DadbodUI.ExecuteEvent)
---@alias DadbodUI.AutocmdOpts { group?: integer|string, once?: boolean }

---@class DadbodUI.BridgeModule
---@field is_available fun(): boolean
---@field parse_url fun(url: string): DadbodUI.ParsedUrl
---@field resolve fun(url: string): string
---@field safe_url fun(url: string): string
---@field scheme_of fun(url: string): string
---@field schemes fun(): string[]
---@field supports fun(url: string, name: string): boolean
---@field adapter_call fun(url: string, name: string, args: any[]|nil, default: any|nil): any
---@field dispatch fun(url: string, name: string, ...: any): any
---@field input_extension fun(url: string): string
---@field output_extension fun(url: string): string
---@field dbout_input fun(file: string): string|nil
---@field connect fun(url: string): string
---@field connect_async fun(url: string, on_result: DadbodUI.ConnectAsyncCallback)
---@field can_cancel fun(): boolean
---@field cancel fun(bufnr: integer|nil)
---@field systemlist fun(cmd: string[], input: string|nil): string[]
---@field command fun(url: string, mode: string|nil): string[]
---@field run_many fun(specs: DadbodUI.CommandSpec[], on_done: DadbodUI.RunManyCallback)
---@field run_many_sync fun(specs: DadbodUI.CommandSpec[], timeout_ms: integer|nil): DadbodUI.SystemCompleted[]
---@field execute fun(url: string, sql: string, quiet?: boolean, vertical?: boolean)
---@field execute_buffer fun(quiet?: boolean, vertical?: boolean)
---@field execute_file fun(file: string, url: string, quiet?: boolean, vertical?: boolean)
---@field execute_lines fun(lines: string[], url: string, quiet?: boolean, vertical?: boolean)
---@field on_pre fun(cb: DadbodUI.ExecuteEventCallback, opts?: DadbodUI.AutocmdOpts): integer
---@field on_post fun(cb: DadbodUI.ExecuteEventCallback, opts?: DadbodUI.AutocmdOpts): integer

---@private
local fn = vim.fn
---@private
local api = vim.api

---@type DadbodUI.BridgeModule
---@diagnostic disable-next-line: missing-fields
local M = {}

--- True when vim-dadbod is installed (its autoload is on the runtimepath).
---@return boolean
function M.is_available()
  return fn.globpath(vim.o.runtimepath, 'autoload/db.vim') ~= ''
end

---@private
---@return nil
local function require_dadbod()
  if not M.is_available() then
    error('[dadbod-ui] vim-dadbod is not installed or not on the runtimepath', 2)
  end
end

-- URL ------------------------------------------------------------------------

--- Parse a connection URL into its components.
--- `scheme` is the RAW scheme from the URL (e.g. `postgres`, not `postgresql`).
--- Network URLs return `host`/`port`/`user`/`password`/`path`; file-style URLs
--- (sqlite) return `opaque` instead.
---@param url string
---@return DadbodUI.ParsedUrl
function M.parse_url(url)
  require_dadbod()
  return fn['db#url#parse'](url)
end

--- Resolve a URL: expand env vars, `g:dbs` variables, scheme aliases and file
--- paths. Adapter functions must be called with a resolved URL.
---@param url string
---@return string
function M.resolve(url)
  require_dadbod()
  return fn['db#resolve'](url)
end

--- URL with the password stripped, for display in the drawer / statusline.
---@param url string
---@return string
function M.safe_url(url)
  require_dadbod()
  return fn['db#url#safe_format'](url)
end

--- Raw scheme of a URL (e.g. `postgres`, `sqlite`). Convenience over parse_url.
---@param url string
---@return string
function M.scheme_of(url)
  return M.parse_url(url).scheme
end

-- Adapters -------------------------------------------------------------------

--- All adapter schemes dadbod knows about (canonical names).
---@return string[]
function M.schemes()
  require_dadbod()
  return fn['db#adapter#schemes']()
end

--- Does the adapter for `url` implement `name`? Resolves `url` first.
---@param url string
---@param name string
---@return boolean
function M.supports(url, name)
  return fn['db#adapter#supports'](M.resolve(url), name) == 1
end

--- Call adapter function `name` for `url`. Resolves `url` first so raw schemes
--- (postgres, sqlite3) reach the right adapter. When the adapter does not
--- implement `name`, returns `default` (if provided) instead of erroring.
---@param url string
---@param name string
---@param args any[]|nil
---@param default any|nil
---@return any
function M.adapter_call(url, name, args, default)
  url = M.resolve(url)
  args = args or {}
  if default ~= nil then
    return fn['db#adapter#call'](url, name, args, default)
  end
  return fn['db#adapter#call'](url, name, args)
end

--- Dispatch adapter function `name` with the resolved url as its first argument.
---@param url string
---@param name string
---@return any
function M.dispatch(url, name, ...)
  return fn['db#adapter#dispatch'](M.resolve(url), name, ...)
end

--- File extension dadbod uses for query input files (default `sql`).
---@param url string
---@return string
function M.input_extension(url)
  return M.adapter_call(url, 'input_extension', {}, 'sql')
end

--- File extension dadbod uses for result output files (default `dbout`).
---@param url string
---@return string
function M.output_extension(url)
  return M.adapter_call(url, 'output_extension', {}, 'dbout')
end

--- The query-input file path dadbod records on a `.dbout` result buffer.
--- dadbod sets a result buffer's `b:db` to a TABLE describing the execution,
--- whose `input` field is the temp file holding the SQL that produced the rows.
--- That `b:db` table shape is a dadbod internal, so reading `.input` lives here
--- behind the engine boundary rather than leaking into the UI.
---
--- Returns the input path, or nil when the buffer is unknown, has no `b:db`
--- table, or that table carries no usable `input`.
---@param file string  the `.dbout` buffer's name/path
---@return string|nil
function M.dbout_input(file)
  local bufnr = fn.bufnr(file)
  if bufnr < 0 then
    return nil
  end
  local db = fn.getbufvar(bufnr, 'db')
  if type(db) ~= 'table' then
    return nil
  end
  local input = db.input
  if type(input) ~= 'string' or input == '' then
    return nil
  end
  return input
end

-- Connection -----------------------------------------------------------------

--- Validate / prepare a connection, returning the resolved connection string.
--- May prompt (e.g. for a password) exactly as dadbod does.
---@param url string
---@return string
function M.connect(url)
  require_dadbod()
  return fn['db#connect'](url)
end

--- Non-blocking variant of `connect`. dadbod's `db#connect` runs its auth probe
--- through the SYNCHRONOUS `systemlist`, which blocks Neovim for a full round-trip
--- to the server (the "UI freezes while connecting" symptom). This reproduces the
--- exact probe dadbod would run -- same per-adapter command, same auth input --
--- but dispatches it via `vim.system` (async), calling `on_result(ok, conn)` on
--- the main loop when it lands. `conn` is the resolved (authed) url on success,
--- or the error message on failure.
---
--- Faithfulness / fallbacks: adapters that short-circuit auth (`auth_input` is
--- `v:false`, e.g. bigquery/jq) resolve immediately with no probe, exactly as
--- `db#connect` returns early. If the probe fails with an auth error AND the url
--- carries a user but no password, we defer to the BLOCKING `db#connect` so its
--- `inputsecret` prompt + password caching behave identically -- blocking there
--- is moot since the user is being prompted anyway. Any error building the probe
--- (unknown adapter shape, etc.) also falls back to the blocking connect, so this
--- is never worse than the original, only faster in the common no-prompt case.
---@param url string
---@param on_result fun(ok: boolean, conn: string)
---@return nil
function M.connect_async(url, on_result)
  require_dadbod()
  local resolved = M.resolve(url)
  local function finish(ok, conn)
    vim.schedule(function()
      on_result(ok, conn)
    end)
  end
  -- Fall back to the faithful blocking connect (identical prompting/messaging).
  local function fallback_sync()
    vim.schedule(function()
      local ok, conn = pcall(M.connect, url)
      on_result(ok, conn)
    end)
  end

  -- Build the probe dadbod's `db#connect` runs (mirrors its `s:filter(url, in)` +
  -- `auth_input` contract). Guarded: any failure here drops to the blocking path.
  local built, probe = pcall(function()
    local auth_input = M.adapter_call(resolved, 'auth_input', {}, '\n')
    -- `v:false` => the adapter needs no auth probe; connect returns immediately.
    if auth_input == false or auth_input == nil then
      return { short_circuit = true }
    end
    auth_input = tostring(auth_input)
    if M.supports(resolved, 'input') then
      -- The adapter reads its auth input from a file (`-f <tmp>`), not stdin.
      -- Mirror dadbod's `s:filter`: `db#adapter#dispatch(url, 'input', in)` --
      -- dispatch forwards the file arg (adapter_call would drop it).
      local input_file = fn.tempname()
      fn.writefile(vim.split(auth_input, '\n', { plain = true }), input_file, 'b')
      return { cmd = M.dispatch(resolved, 'input', input_file), input_file = input_file }
    end
    local op = M.supports(resolved, 'filter') and 'filter' or 'interactive'
    return { cmd = M.dispatch(resolved, op), stdin = auth_input }
  end)
  if not built then
    return fallback_sync()
  end
  if probe.short_circuit then
    return finish(true, resolved)
  end

  -- Remove the auth-input temp file (if the adapter used one) once the probe is
  -- done -- on success, failure, or a spawn that never started.
  local function cleanup_input()
    if probe.input_file then
      pcall(fn.delete, probe.input_file)
    end
  end

  -- `vim.system`'s callback runs in a fast event context (|api-fast|), where
  -- reading a Vim option (adapter_call/dispatch -> resolve -> is_available ->
  -- `vim.o.runtimepath`) raises E5560. Do ALL post-processing on the main loop:
  -- everything below touches Vim fns, so the whole body is scheduled and calls
  -- `on_result` directly (finish/fallback_sync would double-schedule).
  -- Guard the spawn: a missing client binary makes `vim.system` throw ENOENT
  -- raw, the callback never fires (drawer stuck "connecting"), and the auth-input
  -- temp file written above leaks. On failure, delete that file and finish with a
  -- clean message matching dadbod's own (`DB: '<exec>' executable not found`).
  local spawned = pcall(vim.system, probe.cmd, { text = true, stdin = probe.stdin }, function(obj)
    vim.schedule(function()
      cleanup_input()
      if obj.code == 0 then
        return on_result(true, resolved)
      end
      -- Mirror `db#connect`'s auth-retry guard: output matches the adapter's auth
      -- pattern (case-insensitive) AND the url has a user with no password. Only
      -- then is a password prompt warranted -- defer to the blocking connect for it.
      local pattern = M.adapter_call(resolved, 'auth_pattern', {}, 'auth\\|login')
      local out = (obj.stdout or '') .. '\n' .. (obj.stderr or '')
      local needs_auth = fn.match(out, '\\c' .. pattern) > -1 and fn.match(resolved, '^[^:]*://[^:/@]*@') > -1
      if needs_auth then
        local ok, conn = pcall(M.connect, url)
        return on_result(ok, conn)
      end
      local err = obj.stderr ~= nil and obj.stderr ~= '' and obj.stderr or (obj.stdout or '')
      on_result(false, 'DB exec error: ' .. err)
    end)
  end)
  if not spawned then
    cleanup_input()
    finish(false, "DB: '" .. tostring(probe.cmd[1]) .. "' executable not found")
  end
end

--- Whether dadbod exposes async cancellation (i.e. the async path is available).
---@return boolean
function M.can_cancel()
  return fn.exists('*db#cancel') == 1
end

--- Cancel the running async query for `bufnr` (current buffer if omitted).
---@param bufnr integer|nil
function M.cancel(bufnr)
  if not M.can_cancel() then
    return
  end
  if bufnr then
    fn['db#cancel'](bufnr)
  else
    fn['db#cancel']()
  end
end

-- Synchronous introspection --------------------------------------------------

--- Run `cmd` (an argv list) synchronously, optionally feeding `input` (a file
--- path). Blocks Neovim. Used for fast schema / table metadata, never for user
--- queries.
---@param cmd string[]
---@param input string|nil
---@return string[]
function M.systemlist(cmd, input)
  require_dadbod()
  if input ~= nil then
    return fn['db#systemlist'](cmd, input)
  end
  return fn['db#systemlist'](cmd)
end

-- Concurrent introspection (fan-out / WaitGroup) -----------------------------

--- Build the argv dadbod uses to talk to `url` in `mode` (`interactive` by
--- default, or `filter` for stdin-fed adapters). Append your query as a final
--- argument, or feed it as `stdin`, then run it yourself -- e.g. through
--- `run_many` -- to control concurrency. This reuses dadbod to construct the
--- correct per-adapter command while we own the process.
---@param url string
---@param mode string|nil  'interactive' (default) | 'filter'
---@return string[]
function M.command(url, mode)
  return M.dispatch(url, mode or 'interactive')
end

--- Run many commands concurrently and join when ALL finish (non-blocking).
---
--- This is the `for { go … }; wg.Wait()` pattern: each `vim.system` call spawns
--- an OS process that runs in parallel, and `on_done` fires once the last one
--- exits. No locking is needed -- the per-process exit callbacks run
--- cooperatively on Neovim's main loop, so there are no data races on the shared
--- `results` table. Wall-clock is the SLOWEST command, not the sum.
---
--- Prefer this in the UI: introspection stays off the main thread, the drawer
--- can show a loading state and fill in as results arrive.
---
--- A spec whose spawn throws (e.g. the client binary is not installed) records a
--- `nil` result in that slot rather than stranding the join, so `on_done` always
--- fires exactly once; callers must tolerate `nil` holes in `results`.
---@param specs DadbodUI.CommandSpec[]
---@param on_done DadbodUI.RunManyCallback  results[i] aligns with specs[i]
---@return nil
function M.run_many(specs, on_done)
  local results = {}
  local remaining = #specs
  if remaining == 0 then
    return on_done(results)
  end
  -- One shared completion path (the wg.Done()): every branch routes through here so
  -- `remaining` reliably reaches 0 and `on_done` fires exactly once. A spawn that
  -- throws (e.g. missing binary) must NOT strand the join -- it records a nil result
  -- for that spec and completes through the same path.
  local function done(i, obj)
    results[i] = obj
    remaining = remaining - 1
    if remaining == 0 then
      vim.schedule(function()
        on_done(results)
      end)
    end
  end
  for i, spec in ipairs(specs) do
    -- spawn now (concurrent); the callback is the wg.Done()
    local spawned = pcall(vim.system, spec.cmd, { text = true, stdin = spec.stdin }, function(obj)
      done(i, obj)
    end)
    if not spawned then
      -- `vim.system` threw (e.g. the binary is not installed): the callback will
      -- never run, so complete this spec here with a nil result.
      done(i, nil)
    end
  end
end

--- Blocking variant: spawn every command FIRST (so they run concurrently), then
--- wait on each handle. Wall-clock ≈ the slowest command, not the sum -- but it
--- blocks Neovim for that duration. Closest to a literal `wg.Wait()`; prefer the
--- async `run_many` in the UI and reserve this for scripts/tests.
---@param specs DadbodUI.CommandSpec[]
---@param timeout_ms integer|nil
---@return DadbodUI.SystemCompleted[]
function M.run_many_sync(specs, timeout_ms)
  local handles = {}
  for i, spec in ipairs(specs) do
    handles[i] = vim.system(spec.cmd, { text = true, stdin = spec.stdin })
  end
  local results = {}
  for i, h in ipairs(handles) do
    results[i] = h:wait(timeout_ms)
  end
  return results
end

-- Asynchronous execution -----------------------------------------------------

-- Command modifiers for a `:DB`/`%DB` invocation, in the order Vim expects them
-- (modifiers, then the command). `silent` suppresses dadbod's synchronous
-- `DB: Running query...` echo while leaving errors intact (we use `silent`, not
-- `silent!`, so a failed dispatch still raises and reaches the caller's pcall).
-- dadbod's *async* `finished in` echo fires later from its job callback and is
-- handled separately (dbout). `vertical` is what makes dadbod's own
-- `silent exe mods .. 'split'/'pedit'` (db.vim) open the `.dbout` result window
-- as a vertical split instead of the default horizontal one -- see
-- `dadbod-ui.config`'s `result_layout`.
---@private
---@param quiet? boolean
---@param vertical? boolean
---@return string
local function mods_prefix(quiet, vertical)
  local mods = quiet and 'silent ' or ''
  if vertical then
    mods = mods .. 'vertical '
  end
  return mods
end

--- Run `sql` against `url` through dadbod's `:DB`. Non-blocking: dadbod manages
--- the job, writes a `.dbout` result file, and fires `*DBExecutePre` /
--- `*DBExecutePost`. Drive the in-buffer loading indicator from `on_pre` /
--- `on_post`. Pass `quiet` to suppress dadbod's `Running query...` echo; pass
--- `vertical` to open the result window as a vertical split.
---
--- `url` is spliced in raw, NOT `fnameescape`-d: `:DB` takes `<q-args>` with no
--- filename expansion, and `fnameescape` backslash-escapes `%`, which mangles a
--- percent-encoded credential (`p%40ss` -> `p\%40ss`) that dadbod's `s:expand_all`
--- never un-escapes -- breaking auth. dadbod's `s:cmd_split` parses the url as a
--- leading non-whitespace token, so a (space-free) url passes through intact.
---
--- A newline in `sql` would terminate the `:DB` Ex command and run the remainder
--- as a second command (injection). Multi-line queries are routed through the
--- temp-file path (`execute_lines`), which dadbod reads verbatim, so inline
--- splicing only ever handles a single line.
---@param url string  resolved connection url
---@param sql string  the query text (single statement)
---@param quiet? boolean
---@param vertical? boolean
function M.execute(url, sql, quiet, vertical)
  require_dadbod()
  if sql:find('\n', 1, true) then
    return M.execute_lines(vim.split(sql, '\n', { plain = true }), url, quiet, vertical)
  end
  vim.cmd(string.format('%sDB %s %s', mods_prefix(quiet, vertical), url, sql))
end

--- Execute the whole current buffer against its `b:db` (dadbod's `%DB`). The
--- buffer must carry a valid `b:db`; non-blocking, same event contract as
--- `execute`. Used by the on-save / execute-query path. Pass `quiet` to suppress
--- dadbod's `Running query...` echo; pass `vertical` to open the result window
--- as a vertical split.
---@param quiet? boolean
---@param vertical? boolean
---@return nil
function M.execute_buffer(quiet, vertical)
  require_dadbod()
  vim.cmd(mods_prefix(quiet, vertical) .. '%DB')
end

--- Execute SQL read from `file` against `url` (dadbod's `DB <url> < file`). Used
--- for bind-param substitution, where the rewritten query is written to a temp
--- file rather than fed inline -- this sidesteps every shell / command-line
--- escaping pitfall of building a `DB <text>` command for arbitrary substituted
--- SQL. Passing the url explicitly (rather than relying on the current buffer's
--- `b:db`) makes execution independent of which buffer is focused when an async
--- prompt resolves. Non-blocking, same event contract as `execute`.
---@param file string
---@param url string  resolved connection url
---@param quiet? boolean
---@param vertical? boolean
---@return nil
function M.execute_file(file, url, quiet, vertical)
  require_dadbod()
  -- `url` is spliced in raw (see `execute`): `fnameescape` corrupts percent-encoded
  -- credentials. `file` stays `fnameescape`-d -- it can hold Vim-special chars, and
  -- tempnames never contain `%`, so this escaping is safe here.
  vim.cmd(string.format('%sDB %s < %s', mods_prefix(quiet, vertical), url, fn.fnameescape(file)))
end

--- Write `lines` to a temp file (named with the adapter's input extension) and
--- execute it against `url` via `execute_file`. The rewritten SQL can be
--- multi-statement and contain arbitrary characters, so we write it out and let
--- dadbod read it rather than building a `DB <text>` command -- this sidesteps
--- every shell / command-line escaping pitfall. The shared "write then run a
--- temp file" path used by both the query controller and pagination re-execution.
---@param lines string[]
---@param url string  resolved connection url
---@param quiet? boolean
---@param vertical? boolean
---@return nil
function M.execute_lines(lines, url, quiet, vertical)
  local ext = M.input_extension(url) or 'sql'
  local file = fn.tempname() .. '.' .. ext
  fn.writefile(lines, file)
  M.execute_file(file, url, quiet, vertical)
end

-- dadbod fires `doautocmd User {output}/DBExecute{Pre,Post}`; the original UI
-- matches these with the trailing-suffix pattern `*DBExecutePre|Post`.
---@private
---@param suffix string
---@param cb DadbodUI.ExecuteEventCallback
---@param opts? DadbodUI.AutocmdOpts
---@return integer
local function on_event(suffix, cb, opts)
  opts = opts or {}
  return api.nvim_create_autocmd('User', {
    group = opts.group,
    once = opts.once,
    pattern = '*' .. suffix,
    callback = function(args)
      cb({
        output_file = (args.match:gsub('/' .. suffix .. '$', '')),
        match = args.match,
      })
    end,
  })
end

--- Subscribe to "query started". `cb` receives `{ output_file = <path> }` -- the
--- result file dadbod is about to populate. Write your loading symbol there.
---@param cb fun(info: DadbodUI.ExecuteEvent)
---@param opts? { group?: integer|string, once?: boolean }
---@return integer  autocmd id
function M.on_pre(cb, opts)
  return on_event('DBExecutePre', cb, opts)
end

--- Subscribe to "query finished". `cb` receives `{ output_file = <path> }`;
--- dadbod has written the rows there, replacing the loading symbol.
---@param cb fun(info: DadbodUI.ExecuteEvent)
---@param opts? { group?: integer|string, once?: boolean }
---@return integer  autocmd id
function M.on_post(cb, opts)
  return on_event('DBExecutePost', cb, opts)
end

return M
