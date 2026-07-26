-- Shared test helpers. The mini.test runner executes every spec in ONE Neovim
-- process (unlike plenary, which forked a fresh Neovim per file), so specs that
-- touch windows, buffers, modes or the dadbod-ui session singleton must start
-- from a known-clean state. `clean_ui()` restores that; call it from a spec's
-- `before_each` when the spec drives real windows/buffers.

local config = require('dadbod-ui.config')
local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')

local M = {}

--- Return to a single normal-mode window over a fresh scratch buffer, drop the
--- dadbod-ui session singleton, and wipe stray dbui/query/result buffers left by
--- earlier specs.
function M.clean_ui()
  -- Leave any insert/visual mode left over from a prior spec.
  vim.cmd('silent! stopinsert')
  if vim.fn.mode() ~= 'n' then
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)
  end
  -- Collapse to one window so `normal!`/feedkeys act on a predictable target.
  pcall(vim.cmd, 'silent! only!')
  -- Reset window-local options a prior spec may have left on the surviving
  -- window. dbout sets `foldmethod=expr`; a leftover fold makes linewise visual
  -- motions (`Vj`) swallow the whole fold, skewing selection-based specs.
  vim.wo.foldenable = false
  vim.wo.foldmethod = 'manual'
  vim.wo.foldexpr = '0'
  -- Reset the session state singleton (drops the cached instance + drawer).
  pcall(function()
    state.reset()
  end)
  -- Wipe leftover plugin buffers so a reopened query buffer can't reuse stale
  -- content; keep the current buffer.
  local cur = vim.api.nvim_get_current_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= cur and vim.api.nvim_buf_is_valid(b) then
      local ok, key = pcall(function()
        return vim.b[b].dbui_db_key_name
      end)
      local ft = vim.bo[b].filetype
      if ft == 'dbui' or ft == 'dbout' or (ok and key ~= nil) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
  end
end

--- A unique, created temp directory. Lives under Neovim's private tempdir, so
--- the OS path is unique per test process and removed when Neovim exits --
--- specs never need to clean it up and parallel checkouts cannot collide.
---@return string
function M.tmp_dir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  return dir
end

--- A throwaway sqlite database seeded with `seed_sql`, for end-to-end specs
--- that execute real queries. Returns the dadbod url AND the raw path (some
--- callers -- e.g. a `{ 'sqlite3', path }` argv -- need the bare file), or nil
--- when the sqlite3 CLI is unavailable (callers `return pending(...)`). The
--- file lives in Neovim's private tempdir, so it is unique per run and removed
--- on exit.
---@param seed_sql string
---@return string? url, string? path
function M.sqlite_db(seed_sql)
  if vim.fn.executable('sqlite3') ~= 1 then
    return nil
  end
  local path = vim.fn.tempname() .. '.db'
  vim.fn.system({ 'sqlite3', path, seed_sql })
  return 'sqlite:' .. path, path
end

--- Buffers whose name ends in `.dbout` (the result buffers). Folds the
--- "scan nvim_list_bufs and match the name" loop specs otherwise repeat.
---@return integer[]
function M.dbout_bufs()
  return vim.tbl_filter(function(b)
    return vim.api.nvim_buf_get_name(b):match('%.dbout$') ~= nil
  end, vim.api.nvim_list_bufs())
end

---@class dbui.test.DrawerOpts
---@field g_dbs? table<string,string> name -> url (default one sqlite connection 'qa')
---@field file_entries? table[] entries as if read from connections.json
---@field config? table overrides merged into the resolved test config
---@field connector? 'echo'|'offline'|fun(url: string): string 'echo' (default) returns the url so entries "connect" and b:db is set; 'offline' returns '' so entries stay unconnected; a function is used as-is (e.g. the real bridge.connect for e2e specs)
---@field async_connector? 'defer'|fun(url: string, on_result: fun(ok: boolean, conn: string)) 'defer' installs a stub that schedule-defers an empty success (mirrors the vim.system backend so the loading spinner is observable); a function is used as-is. Left unstubbed by default.
---@field inputs? string[] queued answers for d.input prompts
---@field confirm? boolean fixed answer for d.confirm (only stubbed when set)

-- Offline specs never persist, so one lazily-created dir serves as the default
-- save_location for every make_drawer that doesn't override it -- no per-call
-- mkdir. Specs that actually write connections.json pass their own tmp dir.
local default_save

--- A drawer over an instance seeded with injected connections -- the canonical
--- offline fixture for drawer/query/dbout specs. Nothing touches a real DB
--- unless a spec passes the real bridge as `connector`.
---@param opts? dbui.test.DrawerOpts
function M.make_drawer(opts)
  opts = opts or {} --[[@as dbui.test.DrawerOpts]]
  if not (opts.config and opts.config.save_location) then
    default_save = default_save or M.tmp_dir()
  end
  local cfg = config.resolve(vim.tbl_deep_extend('force', {
    save_location = default_save,
    drawer = { show_help = false },
  }, opts.config or {}))
  local instance = state.new(cfg):populate({
    env = {},
    g_dbs = opts.g_dbs or { qa = 'sqlite:/tmp/qa.db' },
    file_entries = opts.file_entries or {},
  })
  local d = drawer_mod.new(instance)

  local connector = opts.connector or 'echo'
  if connector == 'echo' then
    d.connector = function(url)
      return url
    end
  elseif connector == 'offline' then
    d.connector = function()
      return ''
    end
  else
    d.connector = connector
  end

  if opts.async_connector == 'defer' then
    d.async_connector = function(_, on_result)
      vim.schedule(function()
        on_result(true, '')
      end)
    end
  elseif type(opts.async_connector) == 'function' then
    d.async_connector = opts.async_connector
  end

  if opts.inputs then
    local i = 0
    d.input = function(_, on_confirm)
      i = i + 1
      on_confirm(opts.inputs[i])
    end
  end
  if opts.confirm ~= nil then
    d.confirm = function()
      return opts.confirm
    end
  end
  return d
end

--- Find a populated entry by connection name.
function M.entry_named(d, name)
  for _, record in ipairs(d.instance.dbs_list) do
    if record.name == name then
      return d.instance.dbs[record.key_name]
    end
  end
end

--- All lines of a buffer.
---@param bufnr integer
---@return string[]
function M.buf_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

--- Whether any line of the buffer contains `text` (plain find, not a pattern).
---@param bufnr integer
---@param text string
---@return boolean
function M.has_line(bufnr, text)
  for _, line in ipairs(M.buf_lines(bufnr)) do
    if line:find(text, 1, true) then
      return true
    end
  end
  return false
end

return M
