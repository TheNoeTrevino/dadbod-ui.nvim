#!/usr/bin/env -S nvim -l

-- Bootstrap lazy.nvim into an isolated `.tests/` stdpath and run the spec suite
-- under mini.test (`--minitest`). Mirrors the setup folke uses in snacks.nvim.
-- vim-dadbod is the one runtime dependency (the query engine the bridge calls).

vim.env.LAZY_STDPATH = '.tests'

-- Prefer a local lazy.nvim clone (offline / fast); fall back to the upstream
-- bootstrap over the network (CI).
local lazypath = vim.fs.normalize(vim.env.LAZY_PATH or (vim.fn.stdpath('data') .. '/lazy/lazy.nvim'))
if vim.fn.isdirectory(lazypath) == 1 then
  loadfile(lazypath .. '/bootstrap.lua')()
else
  load(vim.fn.system('curl -s https://raw.githubusercontent.com/folke/lazy.nvim/main/bootstrap.lua'), 'bootstrap.lua')()
end

require('lazy.minit').setup({
  spec = {
    { dir = vim.uv.cwd() },
    { 'tpope/vim-dadbod', lazy = false },
  },
})

-- Keep the command line quiet during tests.
vim.notify = function() end

-- busted's `pending()` marks a spec skipped; mini.test's busted emulation does
-- not provide it. Our guarded specs call `return pending(msg)` to bow out when a
-- DB binary/url is unavailable, so a no-op that returns nil lets that `return`
-- exit the body cleanly.
_G.pending = function(...) end
