---@mod dadbod-ui.utils  Small shared helpers (port of `autoload/db_ui/utils.vim`)
---
--- Leaf module with no sibling dependencies, so both the drawer and query
--- controllers can `require` it directly without re-introducing their lazy
--- drawer<->query cycle.

local M = {}

--- Strip everything but `[A-Za-z0-9_-]` from `str`. Port of `db_ui#utils#slug`.
---@param str string
---@return string
function M.slug(str)
  return (str:gsub('[^%w_%-]', ''))
end

--- The number of a loaded buffer whose name is exactly `full_path`, else -1.
--- Used instead of `vim.fn.bufnr`, whose pattern matching can falsely match an
--- unrelated buffer (the `.`/`*` in a path are treated as regex).
---@param full_path string
---@return integer
function M.loaded_bufnr(full_path)
  return vim.iter(vim.api.nvim_list_bufs()):find(function(b)
    return vim.api.nvim_buf_is_loaded(b) and vim.api.nvim_buf_get_name(b) == full_path
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
