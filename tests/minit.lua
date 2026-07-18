#!/usr/bin/env -S nvim -l

-- Bootstrap lazy.nvim into an isolated `.tests/` stdpath and run the spec suite
-- under mini.test (`--minitest`). Mirrors the setup folke uses in snacks.nvim.
-- vim-dadbod is the one runtime dependency (the query engine the bridge calls).

-- `.tests/` in the repo by default; the integration runner container points
-- this at a path of its own so it never reuses the host's copy (see
-- integration/Dockerfile).
vim.env.LAZY_STDPATH = vim.env.LAZY_STDPATH or '.tests'

-- Prefer a local lazy.nvim clone (offline / fast); fall back to the upstream
-- bootstrap over the network (CI).
local lazypath = vim.fs.normalize(vim.env.LAZY_PATH or (vim.fn.stdpath('data') .. '/lazy/lazy.nvim'))
if vim.fn.isdirectory(lazypath) == 1 then
  loadfile(lazypath .. '/bootstrap.lua')()
else
  load(vim.fn.system('curl -s https://raw.githubusercontent.com/folke/lazy.nvim/main/bootstrap.lua'), 'bootstrap.lua')()
end

-- busted's `pending()` marks a spec skipped; mini.test's busted emulation does
-- not provide it. Our guarded specs call `return pending(msg)` to bow out when a
-- DB binary/url is unavailable, so a no-op that returns nil lets that `return`
-- exit the body cleanly. Defined BEFORE setup(): lazy.minit runs the whole
-- suite synchronously inside setup, and integration specs call pending() at
-- collect time (top of a describe body).
_G.pending = function(...) end

-- Keep the command line quiet during tests.
vim.notify = function() end

-- NOTE on quieting: specs that execute real SQL make vim-dadbod echo a line
-- per query ('DB: Running query...', 'DB: Query ... finished in 0.02s'), which
-- buries the test report. It cannot be silenced from here: the completion line
-- is echoed from an async job callback (so `:silent` at the call site never
-- covers it), and under `nvim -l` an `:echo` writes to stdout even while
-- `:redir` is capturing it. `scripts/test` filters the noise out of the output
-- stream instead -- see the FILTER there, and DBUI_TEST_VERBOSE=1 to keep it.

require('lazy.minit').setup({
  spec = {
    { dir = vim.uv.cwd() },
    { 'tpope/vim-dadbod', lazy = false },
    {
      -- Report progress per `describe` block, not per file. The integration
      -- specs name their blocks after the adapter under test ('execute
      -- postgres', 'introspection mysql', ...), so this is what makes it
      -- visible WHICH adapter a run is currently on -- and which one a
      -- failure or a hang belongs to.
      'echasnovski/mini.test',
      opts = function(_, opts)
        opts.execute = opts.execute or {}
        opts.execute.reporter = require('mini.test').gen_reporter.stdout({ group_depth = 2 })
        return opts
      end,
    },
  },
  -- lazy's own headless output (per-plugin fetch/status/checkout task lines)
  -- goes through io.stdout, so `:redir` above cannot catch it -- turn it off
  -- here instead. Errors during install still surface.
  headless = vim.env.DBUI_TEST_VERBOSE ~= '1' and { process = false, log = false, task = false } or nil,
})
