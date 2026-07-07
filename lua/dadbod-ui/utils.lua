-- Small shared helpers.
--
-- Leaf module with no sibling dependencies, so both the drawer and query
-- controllers can `require` it directly without re-introducing their lazy
-- drawer<->query cycle.

---@class DadbodUI.UtilsModule
---@field qualified_name fun(name: string, group?: string): string
---@field display_name fun(name: string, group?: string): string
---@field canonical_path fun(path: string): string
---@field same_path fun(a: string, b: string): boolean
---@field loaded_bufnr fun(full_path: string): integer
---@field is_file fun(path: string): boolean
---@field is_dir fun(path: string): boolean
---@field opposite_position fun(win_position: string): string

---@type DadbodUI.UtilsModule
---@diagnostic disable-next-line: missing-fields
local M = {}

---@private
local is_win = vim.fn.has('win32') == 1

--- The group-qualified connection identifier: `{group}_{name}` when grouped,
--- else just `{name}`. This is the SINGLE source of truth for how a connection
--- maps to its on-disk names -- the save folder AND its tmp query folder --
--- so a name reused across groups is namespaced per group and never collides or
--- resolves to the wrong connection. Anything that derives a buffer/save path or
--- resolves one back to a connection must go through here.
---@param name string
---@param group? string
---@return string
function M.qualified_name(name, group)
  if group == nil or group == '' then
    return name
  end
  return group .. '_' .. name
end

--- The human-facing connection label: `{group}/{name}` when grouped, else just
--- `{name}`. Used in the winbar and connection pickers so a name reused across
--- groups reads unambiguously. Display only -- use qualified_name for the on-disk
--- identifier (buffers/save folder).
---@param name string
---@param group? string
---@return string
function M.display_name(name, group)
  if group == nil or group == '' then
    return name
  end
  return group .. '/' .. name
end

--- Canonical form of `path` for EQUALITY checks: absolute, forward slashes,
--- lowercased on Windows (a case-insensitive filesystem). We build paths with
--- `/` while buffer names use `\` on Windows, so every comparison of a generated
--- path against a Neovim-reported one must go through here (or `same_path`).
--- Comparison only; never use the lowercased result as a real path. The `''`
--- guard matters: abspath('') is the cwd, which could false-match a real path.
---@param path string
---@return string
function M.canonical_path(path)
  if path == '' then
    return ''
  end
  local p = vim.fs.normalize(vim.fs.abspath(path))
  return is_win and p:lower() or p
end

--- Whether `a` and `b` name the same file, separator- and (on Windows)
--- case-insensitively. See `canonical_path`.
---@param a string
---@param b string
---@return boolean
function M.same_path(a, b)
  return M.canonical_path(a) == M.canonical_path(b)
end

--- The number of a loaded buffer whose name resolves to `full_path`, else -1.
--- Used instead of `vim.fn.bufnr`, whose pattern matching can falsely match an
--- unrelated buffer (the `.`/`*` in a path are treated as regex). Compares
--- canonically so `/` vs `\` (Windows) never hides an already-open buffer.
---@param full_path string
---@return integer
function M.loaded_bufnr(full_path)
  local want = M.canonical_path(full_path)
  return vim.iter(vim.api.nvim_list_bufs()):find(function(b)
    return vim.api.nvim_buf_is_loaded(b) and M.canonical_path(vim.api.nvim_buf_get_name(b)) == want
  end) or -1
end

--- Whether `path` exists and is a regular file.
---@param path string
---@return boolean
function M.is_file(path)
  return (vim.uv.fs_stat(path) or {}).type == 'file'
end

--- Whether `path` exists and is a directory.
---@param path string
---@return boolean
function M.is_dir(path)
  return (vim.uv.fs_stat(path) or {}).type == 'directory'
end

--- The split modifier for placing a query window on the side opposite the
--- drawer: `botright` when the drawer is on the left, otherwise `topleft`.
---@param win_position string  the drawer's `win_position` config ('left' | 'right')
---@return string
function M.opposite_position(win_position)
  return win_position == 'left' and 'botright' or 'topleft'
end

return M
