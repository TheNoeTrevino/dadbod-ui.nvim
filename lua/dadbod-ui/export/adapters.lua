-- Per-adapter export capability access (flags only)
--
-- The flag half of native CLI export (`specs/native-export.md` §4 + Appendix A):
-- which adapters can export, which CLI flags select the canonical delimited
-- extractor, and which (adapter, format) pairs the CLI can emit natively for a
-- straight passthrough. The flag data lives on the adapter specs
-- (`dadbod-ui.adapters`, the `export` field); this module knows how to hand it
-- out, not how to run it -- the orchestrator (`dadbod-ui.export`) composes the
-- flags onto `bridge.command(url)` and runs `vim.system`.
--
-- v1 adapters: postgres, mysql/mariadb, sqlite (DECISION-004). Others return
-- unsupported until their spec gains an `export` field.

---@class DadbodUI.ExportAdaptersModule
---@field supports fun(scheme: string): boolean
---@field formats_for fun(scheme: string): string[]
---@field uses_stdin fun(scheme: string): boolean
---@field extract_args fun(scheme: string): string[]|nil
---@field native_args fun(scheme: string, fmt: string): string[]|nil
---@field is_native fun(scheme: string, fmt: string, prefer_native: boolean): boolean

---@private
local registry = require('dadbod-ui.adapters')

---@type DadbodUI.ExportAdaptersModule
---@diagnostic disable-next-line: missing-fields
local M = {}

---@private
--- Every target format the Lua formatters can produce from the canonical extract;
--- any supported adapter offers all of them (native passthrough is an
--- optimization, never a coverage limit -- DECISION-001).
local ALL_FORMATS = { 'csv', 'json', 'markdown', 'html', 'xml', 'sql', 'tsv' }

---@private
--- The adapter's export config (the spec's `export` field), or nil when the
--- adapter cannot export.
---@param scheme string
---@return { stdin: boolean, extract: string[], native: table<string, string[]> }|nil
local function adapter(scheme)
  local spec = registry.get(scheme)
  return spec and spec.export or nil
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
