-- Shared dbout state: attached drawer + effective config
--
-- The one bit of module state the dbout submodules share with `init`: the
-- attached drawer and the `current_config` helper derived from it. Kept in its
-- own file so `winbar` / `pagination` / `cells` can read the effective config
-- without requiring `init` (which requires them -- that would be circular).

---@class DadbodUI.DboutCtx
--- The drawer the dbout module re-renders through; set by `init` on attach, read
--- live by the submodules (nil until the drawer opens).
---@field attached DadbodUI.Drawer|nil
---@field current_config fun(): DadbodUI.Config
local M = {}

---@type DadbodUI.Drawer|nil
M.attached = nil

--- The effective config: the attached drawer's, or the session singleton's when a
--- dbout buffer is touched before the drawer ever opened.
---@return DadbodUI.Config
function M.current_config()
  if M.attached ~= nil then
    return M.attached.config
  end
  return require('dadbod-ui.state').get().config
end

return M
