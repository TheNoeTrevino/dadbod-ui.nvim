-- Boot guard. dadbod-ui defines no user commands or mappings -- drive it from
-- `require('dadbod-ui.api')` (see the README), so this file only refuses to load
-- on an unsupported Neovim and sets the loaded flag.

if vim.g.loaded_dadbod_ui then
  return
end
if vim.fn.has('nvim-0.12') == 0 then
  vim.notify('dadbod-ui.nvim requires Neovim >= 0.12', vim.log.levels.ERROR)
  return
end
vim.g.loaded_dadbod_ui = true
