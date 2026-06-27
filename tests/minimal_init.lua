-- Minimal init for the plenary-busted spec suite.
--
-- Puts the plugin, plenary.nvim and vim-dadbod on the runtimepath. Dependencies
-- are expected under `.deps/` (run `make deps`), but we fall back to common
-- local installs so the suite can be run ad-hoc without cloning.

local root = vim.fn.getcwd()

local function first_dir(paths)
  for _, p in ipairs(paths) do
    if p ~= '' and vim.fn.isdirectory(vim.fn.expand(p)) == 1 then
      return vim.fn.expand(p)
    end
  end
  return nil
end

local plenary = first_dir({
  root .. '/.deps/plenary.nvim',
  vim.fn.stdpath('data') .. '/lazy/plenary.nvim',
  vim.fn.stdpath('data') .. '/site/pack/*/start/plenary.nvim',
})

local dadbod = first_dir({
  root .. '/.deps/vim-dadbod',
  vim.fn.stdpath('data') .. '/lazy/vim-dadbod',
  -- local checkout used during the port
  root .. '/../vim-dadbod-ui/vim-dadbod',
})

assert(plenary, 'plenary.nvim not found -- run `make deps`')
assert(dadbod, 'vim-dadbod not found -- run `make deps`')

vim.opt.runtimepath:append(root)
vim.opt.runtimepath:append(plenary)
vim.opt.runtimepath:append(dadbod)

vim.cmd('runtime plugin/plenary.vim')
vim.cmd('runtime plugin/dadbod.vim')
