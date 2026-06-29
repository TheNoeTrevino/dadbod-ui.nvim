---@mod dadbod-ui.bridge  Thin pass-through over vim-dadbod (the query engine)
---
--- This module is the ONLY place in the port that talks to vim-dadbod. Every
--- function is a thin wrapper over dadbod's vimscript API (`db#*`) and the `:DB`
--- command. The Lua port keeps dadbod as the engine and owns only the UI, so
--- this file is the engine boundary -- keep it small and faithful.
---
--- vim-dadbod exposes TWO execution paths and we mirror both:
---
---   * Synchronous  -> `systemlist()`. Blocks Neovim. Used for fast schema /
---                     table introspection that populates the drawer.
---   * Asynchronous -> `execute()` via `:DB`. Non-blocking: dadbod spawns a job,
---                     writes a `.dbout` file and fires the User autocmds
---                     `*DBExecutePre` / `*DBExecutePost`. Subscribe with
---                     `on_pre` / `on_post` to drive the in-buffer loading
---                     indicator and the result rendering.
---
--- Scheme resolution note: `db#url#parse` returns the RAW scheme (`postgres`,
--- not `postgresql`), but no adapter is ever dispatched on a raw scheme here.
--- `db#resolve` canonicalizes the scheme via `g:db_adapters` (e.g.
--- `postgres`->`postgresql`, `sqlite3`->`sqlite`) before dispatch, dadbod ships
--- the canonical adapter files (`postgresql.vim`, `sqlite.vim`), and every
--- adapter call in this module resolves the URL first. So no scheme-alias
--- globals (`g:db_adapter_<scheme>`) are needed -- and deliberately NOT setting
--- them keeps `db#adapter#schemes()` canonical: it enumerates `g:db_adapter_*`
--- keys, so aliases would inject phantom non-canonical entries (`postgres`,
--- `sqlite3`) alongside the real ones.

local fn = vim.fn
local api = vim.api

local M = {}

--- True when vim-dadbod is installed (its autoload is on the runtimepath).
---@return boolean
function M.is_available()
  return fn.globpath(vim.o.runtimepath, 'autoload/db.vim') ~= ''
end

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
---@param specs DadbodUI.CommandSpec[]
---@param on_done fun(results: vim.SystemCompleted[])  results[i] aligns with specs[i]
---@return nil
function M.run_many(specs, on_done)
  local results = {}
  local remaining = #specs
  if remaining == 0 then
    return on_done(results)
  end
  for i, spec in ipairs(specs) do
    -- spawn now (concurrent); the callback is the wg.Done()
    vim.system(spec.cmd, { text = true, stdin = spec.stdin }, function(obj)
      results[i] = obj
      remaining = remaining - 1
      if remaining == 0 then
        vim.schedule(function()
          on_done(results)
        end)
      end
    end)
  end
end

--- Blocking variant: spawn every command FIRST (so they run concurrently), then
--- wait on each handle. Wall-clock ≈ the slowest command, not the sum -- but it
--- blocks Neovim for that duration. Closest to a literal `wg.Wait()`; prefer the
--- async `run_many` in the UI and reserve this for scripts/tests.
---@param specs DadbodUI.CommandSpec[]
---@param timeout_ms integer|nil
---@return vim.SystemCompleted[]
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

--- Run `sql` against `url` through dadbod's `:DB`. Non-blocking: dadbod manages
--- the job, writes a `.dbout` result file, and fires `*DBExecutePre` /
--- `*DBExecutePost`. Drive the in-buffer loading indicator from `on_pre` /
--- `on_post`.
---@param url string  resolved connection url
---@param sql string  the query text (single statement)
function M.execute(url, sql)
  require_dadbod()
  vim.cmd(string.format('DB %s %s', fn.fnameescape(url), sql))
end

--- Execute the whole current buffer against its `b:db` (dadbod's `%DB`). The
--- buffer must carry a valid `b:db`; non-blocking, same event contract as
--- `execute`. Used by the on-save / execute-query path.
---@return nil
function M.execute_buffer()
  require_dadbod()
  vim.cmd('%DB')
end

--- Execute the last visual selection against its `b:db` (dadbod's `'<,'>DB`).
--- Non-blocking, same event contract as `execute`.
---@return nil
function M.execute_range()
  require_dadbod()
  vim.cmd([['<,'>DB]])
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
---@return nil
function M.execute_file(file, url)
  require_dadbod()
  vim.cmd(string.format('DB %s < %s', fn.fnameescape(url), fn.fnameescape(file)))
end

-- dadbod fires `doautocmd User {output}/DBExecute{Pre,Post}`; the original UI
-- matches these with the trailing-suffix pattern `*DBExecutePre|Post`.
---@param suffix string
---@param cb fun(info: DadbodUI.ExecuteEvent)
---@param opts? { group?: integer|string, once?: boolean }
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
