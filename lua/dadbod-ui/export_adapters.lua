---@mod dadbod-ui.export_adapters  Per-adapter export capability matrix (flags only)
---
--- The data half of native CLI export (`specs/native-export.md` §4 + Appendix A):
--- which adapters can export, which CLI flags select the canonical delimited
--- extractor, and which (adapter, format) pairs the CLI can emit natively for a
--- straight passthrough. This module knows FLAGS, not how to run them -- the
--- orchestrator (`dadbod-ui.export`) composes these onto `bridge.command(url)` and
--- runs `vim.system`. Mirrors `dadbod-ui.paginator`: a self-contained per-scheme
--- table gating support, keyed by both raw and canonical scheme names.
---
--- v1 adapters: postgres, mysql/mariadb, sqlite (DECISION-004). Others return
--- unsupported until their row is added.

---@class DadbodUI.ExportAdaptersModule
---@field supports fun(scheme: string): boolean
---@field formats_for fun(scheme: string): string[]
---@field uses_stdin fun(scheme: string): boolean
---@field extract_args fun(scheme: string): string[]|nil
---@field native_args fun(scheme: string, fmt: string): string[]|nil
---@field is_native fun(scheme: string, fmt: string, prefer_native: boolean): boolean

---@type DadbodUI.ExportAdaptersModule
---@diagnostic disable-next-line: missing-fields
local M = {}

---@private
--- Every target format the Lua formatters can produce from the canonical extract;
--- any supported adapter offers all of them (native passthrough is an
--- optimization, never a coverage limit -- DECISION-001).
local ALL_FORMATS = { 'csv', 'json', 'markdown', 'html', 'xml', 'sql', 'tsv' }

---@private
-- The OS null device, used to skip the CLI's user rc file (see the rc-suppression
-- flags below). `/dev/null` on unix, `NUL` on Windows.
local NULLDEV = vim.fn.has('win32') == 1 and 'NUL' or '/dev/null'

---@private
-- Per-adapter export config. `stdin` = deliver the query on stdin (else append it
-- as the final argv element -- after the trailing `-c` for postgres). `extract` =
-- the canonical delimited mode (the faithful row source we parse). `native` = the
-- CLI flags that emit a given target format directly (passthrough candidate); a
-- format absent here is produced by the Lua formatter from the extract.
--
-- Every arg list begins with the adapter's rc-suppression flag so a user's
-- ~/.psqlrc / ~/.sqliterc cannot inject lines (e.g. `\timing`, `.nullvalue`) into
-- the strictly-parsed delimited output. mysql is delivered via stdin and `--batch`
-- already forces clean TSV framing; `--no-defaults` is deliberately NOT used as it
-- would also drop ~/.my.cnf credentials.
local postgres = {
  stdin = false,
  extract = { '--no-psqlrc', '--csv', '-c' },
  native = { csv = { '--no-psqlrc', '--csv', '-c' }, html = { '--no-psqlrc', '-H', '-c' } },
}
---@private
local mysql = {
  stdin = true,
  extract = { '--batch' },
  -- NB: `tsv` is NOT native. mysql `--batch` emits literal `\N` for NULL and
  -- backslash-escaped values; the Lua TSV formatter (fed by the `--batch` extract)
  -- renders NULL -> empty consistently with postgres/sqlite, so TSV is uniformly
  -- the formatter across adapters.
  native = { html = { '--html' }, xml = { '--xml' } },
}
---@private
local sqlite = {
  -- stdin delivery (not a positional arg): sqlite3 treats a positional SQL string
  -- beginning with `-` (e.g. a `-- comment` line) as an unknown option and aborts.
  stdin = true,
  extract = { '-init', NULLDEV, '-csv', '-header' },
  native = {
    csv = { '-init', NULLDEV, '-csv', '-header' },
    json = { '-init', NULLDEV, '-json' },
    -- NB: sqlite's `-markdown` is deliberately NOT native. Its column alignment
    -- for numeric cells changed between sqlite3 releases (older builds
    -- left-justify, newer ones right-justify), so the raw passthrough is not
    -- reproducible across environments. The Lua markdown formatter is used
    -- everywhere instead (uniform with postgres/mysql markdown, deterministic
    -- output -- verified in the export integration suite).
    -- NB: sqlite's `-html` is deliberately NOT native. It emits a bare `<TR>`
    -- fragment (no `<table>` wrapper) and renders NULL as the literal text
    -- `null`; the Lua HTML formatter produces a proper `<table><thead><tbody>`
    -- with NULL -> empty, so sqlite HTML always goes through the formatter
    -- (verified in T16). postgres `-H` / mysql `--html` emit full tables and stay
    -- native.
  },
}

---@private
-- scheme -> config, keyed by both the raw url scheme (e.g. `postgres`, `sqlite3`)
-- and the canonical adapter name, so a lookup works regardless of which the caller
-- holds (same dual-keying as `dadbod-ui.paginator`).
local adapters = {
  postgres = postgres,
  postgresql = postgres,
  mysql = mysql,
  mariadb = mysql,
  sqlite = sqlite,
  sqlite3 = sqlite,
}

---@private
---@param scheme string
---@return table|nil
local function adapter(scheme)
  return adapters[(scheme or ''):lower()]
end

--- Whether export is supported for `scheme`.
---@param scheme string
---@return boolean
function M.supports(scheme)
  return adapter(scheme) ~= nil
end

--- The target formats offered for `scheme` (all of them when supported, else an
--- empty list). A fresh copy per call so callers can sort/mutate freely.
---@param scheme string
---@return string[]
function M.formats_for(scheme)
  if not M.supports(scheme) then
    return {}
  end
  return vim.deepcopy(ALL_FORMATS)
end

--- Whether the query is delivered on stdin (vs appended as the final argv element).
---@param scheme string
---@return boolean
function M.uses_stdin(scheme)
  local a = adapter(scheme)
  return a ~= nil and a.stdin or false
end

--- The canonical delimited-extractor flags for `scheme` (appended to the base
--- argv), or nil for an unsupported scheme. A fresh copy per call.
---@param scheme string
---@return string[]|nil
function M.extract_args(scheme)
  local a = adapter(scheme)
  return a and vim.deepcopy(a.extract) or nil
end

---@private
--- The adapter's own native-passthrough flag table for `(scheme, fmt)` (shared,
--- never mutated), or nil when the CLI cannot emit that format directly.
---@param scheme string
---@param fmt string
---@return string[]|nil
local function native(scheme, fmt)
  local a = adapter(scheme)
  return a and a.native[fmt] or nil
end

--- The native-passthrough flags for `(scheme, fmt)`, or nil when the CLI cannot
--- emit that format directly (the caller then extracts + Lua-formats). A fresh
--- copy per call.
---@param scheme string
---@param fmt string
---@return string[]|nil
function M.native_args(scheme, fmt)
  local args = native(scheme, fmt)
  return args and vim.deepcopy(args) or nil
end

--- Whether `(scheme, fmt)` should take the native passthrough path: the adapter
--- can emit it natively AND `prefer_native` is on (DECISION-001).
---@param scheme string
---@param fmt string
---@param prefer_native boolean
---@return boolean
function M.is_native(scheme, fmt, prefer_native)
  return prefer_native and native(scheme, fmt) ~= nil
end

return M
