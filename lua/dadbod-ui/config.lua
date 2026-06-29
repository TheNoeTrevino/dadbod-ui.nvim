---@mod dadbod-ui.config  Defaults and option resolution
---
--- The canonical option surface is the `setup()` table (snake_case keys). For a
--- smooth migration we also read the legacy `g:db_ui_*` globals: precedence is
--- defaults < legacy globals < `setup()` opts.

local M = {}

--- Built-in defaults. Keys mirror the original `g:db_ui_*` options with the
--- `db_ui_` prefix dropped. Booleans are real Lua booleans (the legacy globals
--- use 0/1 and are coerced on read).
---@type DadbodUI.Config
M.defaults = {
  save_location = '~/.local/share/db_ui',
  tmp_query_location = '',
  table_helpers = {},
  default_query = 'SELECT * from "{table}" LIMIT 200;',
  execute_on_save = false,
  auto_execute_table_helpers = false,
  env_variable_url = 'DBUI_URL',
  env_variable_name = 'DBUI_NAME',
  dotenv_variable_prefix = 'DB_UI_',
  disable_progress_bar = false,
  notification_width = 40,
  winwidth = 40,
  win_position = 'left',
  show_help = true,
  show_database_icon = false,
  use_nerd_fonts = false,
  ---@type table  icon overrides (see dadbod-ui.icons)
  icons = {},
  use_postgres_views = true,
  hide_schemas = {},
  bind_param_pattern = ':\\w\\+',
  drawer_sections = { 'new_query', 'buffers', 'saved_queries', 'schemas' },
  expand_groups = true,
  dbout_list_sort = 'asc',
  force_echo_notifications = false,
  disable_info_notifications = false,
  use_nvim_notify = false,
  is_oracle_legacy = false,
  debug = false,
  disable_mappings = false,
  disable_mappings_dbui = false,
  disable_mappings_dbout = false,
  disable_mappings_sql = false,
  disable_mappings_javascript = false,
  ---@type DadbodUI.BufferNameGenerator|nil  custom buffer name generator
  buffer_name_generator = nil,
  ---@type DadbodUI.TableNameSorter|nil  custom table-list sorter
  table_name_sorter = nil,
}

-- The two function-valued options used the capitalized `g:Db_ui_*` globals.
local funcref_globals = {
  buffer_name_generator = 'Db_ui_buffer_name_generator',
  table_name_sorter = 'Db_ui_table_name_sorter',
}

-- vimscript stores booleans as 0/1; in Lua 0 is truthy, so coerce per type.
---@param default any
---@param value any
---@return any
local function coerce(default, value)
  if type(default) == 'boolean' and type(value) == 'number' then
    return value ~= 0
  end
  return value
end

-- Read a legacy global for `key`, or nil when unset. `0` funcref globals (the
-- "disabled" sentinel) are treated as nil.
---@param key string
---@param default any
---@return any
local function legacy_global(key, default)
  local g = funcref_globals[key]
  if g then
    local v = vim.g[g]
    if v == nil or v == 0 then
      return nil
    end
    return v
  end
  return coerce(default, vim.g['db_ui_' .. key])
end

--- Resolve effective config: defaults < legacy `g:db_ui_*` globals < `opts`.
---@param opts? table  partial config overrides
---@return DadbodUI.Config
function M.resolve(opts)
  local out = vim.deepcopy(M.defaults)
  for key, default in pairs(M.defaults) do
    local legacy = legacy_global(key, default)
    if legacy ~= nil then
      out[key] = legacy
    end
  end
  return vim.tbl_deep_extend('force', out, opts or {})
end

return M
