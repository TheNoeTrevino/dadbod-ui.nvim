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

--- The split modifier for placing a query window on the side opposite the
--- drawer: `botright` when the drawer is on the left, otherwise `topleft`.
---@param win_position string  the drawer's `win_position` config ('left' | 'right')
---@return string
function M.opposite_position(win_position)
  return win_position == 'left' and 'botright' or 'topleft'
end

return M
