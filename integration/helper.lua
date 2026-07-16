-- Shared plumbing for the integration specs (loaded with
-- `dofile('integration/helper.lua')` -- run.sh runs from the repo root).
--
-- Everything here builds REAL sessions: the drawer keeps its default
-- bridge-backed connectors, queries run through dadbod against the live
-- servers run.sh stood up, and completion is observed through dadbod's own
-- `*DBExecutePost` event. The only test double is the notification capture --
-- and it records, it doesn't stub behavior out.

local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')
local bridge = require('dadbod-ui.bridge')
local notify = require('dadbod-ui.notifications')

local M = {}

-- The adapters under test, from run.sh's env. An empty url means the server is
-- not up (e.g. running one spec ad-hoc) -- specs skip it as pending.
-- `schemas`: the adapter lists schemas (vs the flat tables-only path).
-- `plan_marker`: text a real EXPLAIN of `SELECT * FROM people` must contain.
-- `error_markers`: how the adapter CLI spells a failure inside result text --
-- dadbod surfaces statement errors as output, not always as a notification.
M.adapters = {
  {
    name = 'postgres',
    url = vim.env.DBUI_IT_PG_URL or '',
    schemas = true,
    default_schema = 'public',
    routines = true,
    plan_marker = 'Seq Scan',
    error_markers = { 'ERROR:' },
    extra_schema = 'app',
    extra_schema_table = 'orders_archive',
  },
  {
    name = 'mysql',
    url = vim.env.DBUI_IT_MYSQL_URL or '',
    schemas = false,
    routines = true,
    plan_marker = 'people',
    error_markers = { 'ERROR ' },
  },
  {
    name = 'mariadb',
    url = vim.env.DBUI_IT_MARIADB_URL or '',
    schemas = false,
    routines = true,
    plan_marker = 'people',
    error_markers = { 'ERROR ' },
  },
  {
    name = 'sqlite',
    url = vim.env.DBUI_IT_SQLITE_URL or '',
    schemas = false,
    routines = false,
    plan_marker = 'SCAN',
    error_markers = { 'Parse error', 'Runtime error', 'Error:' },
  },
  -- Opt-in extras (run.sh exports these urls only under DBUI_IT_EXTRA=1 with
  -- the matching host client installed). mongodb is not SQL and has its own
  -- spec (integration/mongodb/) instead of an entry here.
  {
    name = 'clickhouse',
    url = vim.env.DBUI_IT_CH_URL or '',
    schemas = true,
    default_schema = 'dbui', -- clickhouse lists databases as schemas
    routines = false,
    plan_marker = 'people', -- ReadFromMergeTree (dbui.people)
    error_markers = { 'DB::Exception' },
  },
  {
    name = 'sqlserver',
    url = vim.env.DBUI_IT_MSSQL_URL or '',
    schemas = true,
    default_schema = 'dbo',
    routines = true,
    plan_marker = 'people', -- unused: sqlserver declares no explain template
    error_markers = { 'Msg ' },
  },
}

--- Build a drawer over ONE real connection -- no injected connectors, so
--- expanding/executing talks to the live server.
---@param adapter { name: string, url: string }
---@param overrides? table  config overrides
function M.make_drawer(adapter, overrides)
  local cfg = config.resolve(vim.tbl_deep_extend('force', {
    save_location = '/tmp/dbui_it/' .. adapter.name,
    drawer = { show_help = false },
  }, overrides or {}))
  local instance = state.new(cfg):populate({ env = {}, g_dbs = { it = adapter.url }, file_entries = {} })
  return drawer_mod.new(instance)
end

--- The single connection entry of a `make_drawer` session.
function M.entry(d)
  return d.instance.dbs[d.instance.dbs_list[1].key_name]
end

--- The concatenated text of every open .dbout result buffer.
function M.dbout_text()
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match('%.dbout$') then
      vim.list_extend(out, vim.api.nvim_buf_get_lines(b, 0, -1, false))
    end
  end
  return table.concat(out, '\n')
end

--- Wait (pumping the loop) until `cond()` is truthy; false on timeout.
function M.wait(cond, ms)
  return vim.wait(ms or 30000, cond, 50)
end

--- Wait until the .dbout text contains `text` (plain find).
function M.wait_for_text(text, ms)
  return M.wait(function()
    return M.dbout_text():find(text, 1, true) ~= nil
  end, ms)
end

--- Subscribe a counter to dadbod's "query finished" event. Returns a table
--- whose `n` increments on every DBExecutePost -- the reliable completion
--- signal even for empty result sets.
function M.post_counter()
  local counter = { n = 0 }
  counter.autocmd = bridge.on_post(function()
    counter.n = counter.n + 1
  end)
  return counter
end

--- Record notifications instead of displaying them (behavior otherwise real).
--- Returns { errors = {...}, infos = {...}, restore = fn }.
function M.capture_notifications()
  local cap = { errors = {}, infos = {} }
  local orig_error, orig_info = notify.error, notify.info
  notify.error = function(msg)
    table.insert(cap.errors, msg)
  end
  notify.info = function(msg)
    table.insert(cap.infos, msg)
  end
  cap.restore = function()
    notify.error, notify.info = orig_error, orig_info
  end
  return cap
end

--- Open a query buffer attached to the session's connection and fill it.
--- Returns the buffer number.
function M.open_query(d, lines)
  d:open()
  local entry = M.entry(d)
  d:query():open({ type = 'query', key_name = entry.key_name }, 'edit')
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

--- Assert the current .dbout text carries none of `adapter`'s CLI error
--- markers (dadbod surfaces failed statements as result text).
function M.assert_no_error_text(adapter, context)
  local text = M.dbout_text()
  for _, marker in ipairs(adapter.error_markers or {}) do
    assert(
      text:find(marker, 1, true) == nil,
      ('%s: result text contains %q:\n%s'):format(context or 'result', marker, text)
    )
  end
end

--- Wipe every .dbout buffer (isolate result assertions between cases).
function M.clear_dbout()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match('%.dbout$') then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
end

--- Full between-case cleanup: dbout buffers gone, drawer closed, one clean
--- window left (the suite runs in ONE Neovim process).
function M.cleanup(d)
  M.clear_dbout()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if name:match('%.dbui/') or vim.bo[b].filetype == 'sql' or vim.bo[b].filetype == 'mysql' then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  if d then
    pcall(function()
      d:close()
    end)
  end
  pcall(vim.cmd, 'silent! only!')
end

return M
