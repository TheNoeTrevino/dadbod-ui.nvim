---@toc_entry Configuration
---@tag dadbod-ui-configuration
---@text
--- # Configuration ~
---
--- Options are passed to |dadbod-ui.setup()| as a table with snake_case keys
--- (the field surface is |DadbodUI.Config|). The `g:db_ui_*` globals are also
--- read; precedence is defaults < `g:db_ui_*` globals < `setup()` opts. Every option has a
--- sensible default, so `setup()` is optional. See `M.defaults` in
--- `lua/dadbod-ui/config.lua` for the full default table.

---@class DadbodUI.ConfigModule
---@field defaults DadbodUI.Config
---@field mapping_sections { group: string, title: string }[]
---@field mapping_order table<string, string[]>
---@field resolve fun(opts?: table): DadbodUI.Config

---@private
---@type DadbodUI.ConfigModule
---@diagnostic disable-next-line: missing-fields
local M = {}

--- Built-in defaults. Keys mirror the `g:db_ui_*` options with the
--- `db_ui_` prefix dropped. Booleans are real Lua booleans (the `g:db_ui_*`
--- globals use 0/1 and are coerced on read).
---@type DadbodUI.Config
M.defaults = {
  save_location = '~/.local/share/db_ui',
  tmp_query_location = '',
  table_helpers = {},
  -- Display order for a table's helpers (`List`, `Columns`, ..., plus any
  -- adapter extra or user-added `table_helpers` entry) under an expanded
  -- table in the drawer. Named helpers render first, in this sequence, when
  -- present for the adapter (a name the adapter doesn't have is skipped, not
  -- shown blank); any present helper not named here falls back after those,
  -- sorted alphabetically. Defaults to the standard drawer help-key sequence.
  table_helpers_order = { 'List', 'Columns', 'Indexes', 'Primary Keys', 'Foreign Keys', 'References' },
  default_query = 'SELECT * from "{table}" LIMIT 200;',
  execute_on_save = false,
  auto_execute_table_helpers = false,
  page_size = 200,
  env_variable_url = 'DBUI_URL',
  env_variable_name = 'DBUI_NAME',
  dotenv_variable_prefix = 'DB_UI_',
  disable_progress_bar = false,
  notification_width = 40,
  winwidth = 40,
  win_position = 'left',
  -- Split direction dadbod opens the `.dbout` result window in. dadbod itself
  -- decides horizontal vs. vertical off the command modifiers on `:DB`/`%DB`
  -- (see bridge.lua's execute functions), so this only steers which modifier we
  -- prefix. 'horizontal' is the default layout.
  result_layout = 'horizontal',
  show_help = true,
  show_database_icon = false,
  use_nerd_fonts = false,
  ---@type table  icon overrides (see dadbod-ui.icons)
  icons = {},
  use_postgres_views = true,
  hide_schemas = {},
  bind_param_pattern = ':\\w\\+',
  -- Drawer sections under an expanded connection, in render order. `procedures`
  -- lists the connection's stored procedures/functions (schema-supporting
  -- adapters nest them per schema); it renders only when the adapter supports
  -- routines and at least one exists, so it is invisible for e.g. sqlite.
  drawer_sections = { 'new_query', 'buffers', 'saved_queries', 'schemas', 'procedures' },
  expand_groups = true,
  dbout_list_sort = 'asc',
  force_echo_notifications = false,
  disable_info_notifications = false,
  use_nvim_notify = false,
  -- Post-execute feedback: instead of dadbod's `DB: Running query...` /
  -- `finished in ...` command-line echoes (and our own "Executing query..."
  -- notification), show the completion + elapsed time inline. `result_buffer`
  -- pins a `winbar` summary to the top of the `.dbout` window; `query_buffer` puts
  -- ghost text trailing the line you executed from. When `enabled`, dadbod's two
  -- echoes are suppressed so the inline summary is the single source of feedback.
  query_time = {
    enabled = true,
    result_buffer = true,
    query_buffer = true,
    show_row_count = true,
  },
  -- Show the connection a query buffer targets in a right-aligned `winbar` at the
  -- top of the buffer's window, formatted `group/name` (or just `name` when the
  -- connection is ungrouped). Follows the buffer into new splits; the `.dbout`
  -- result buffers (which own their winbar) and the drawer are untouched.
  show_buffer_connection = true,
  -- Native CLI result export (see specs/native-export.md). `prefer_native` writes
  -- the CLI's own output when it can emit the target format directly (DECISION-001);
  -- turn it off to force the consistent Lua formatters for every adapter.
  -- `default_path` ('' => cwd) is the directory the export-path prompt defaults to;
  -- `coerce_numbers` opts the JSON/SQL formatters into emitting numeric/boolean
  -- literals (off by default since the CSV extract is untyped). The per-format
  -- sub-tables tune each formatter (see the format docs in dadbod-ui.export_formats).
  export = {
    prefer_native = true,
    default_path = '',
    coerce_numbers = false,
    csv = { delimiter = ',', header = true, quote = '"', null_string = '', line_feed_escape = '' },
    tsv = { line_feed_escape = '\\n' },
    json = { wrap_table_name = true, indent = '\t' },
  },
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
  -- User-configurable lifecycle hooks (see `DadbodUI.Hooks`). A table of optional
  -- functions fired around connect / execute / cancel. `on_connect(event)` is a
  -- transform: returning a string rewrites the connection url before connecting
  -- (e.g. swap a `$password` placeholder for a real secret). Its post/execute/
  -- cancel siblings are observers. A throwing hook is caught + notified, never
  -- aborting the underlying operation. Empty by default; set via `setup{}` opts.
  hooks = {},
  -- Keybindings, grouped by context. Each entry is `{ key, desc, mode? }`; set a
  -- key to 'none' to disable that action (it is then neither bound nor shown in
  -- the `?` help window). Overrides deep-merge, so `mappings.sidebar.delete.key`
  -- can be changed on its own. Display order + section titles are fixed (see
  -- `M.mapping_order` / `M.mapping_sections`). The single source of truth for
  -- both the live keymaps and the help window -- see `dadbod-ui.mappings`.
  mappings = {
    sidebar = {
      help = { key = '?', desc = 'Toggle this help window' },
      toggle = { key = { 'o', '<CR>' }, desc = 'Open/Toggle selected item' },
      toggle_split = { key = 'S', desc = 'Open selected item in a split' },
      quit = { key = 'q', desc = 'Close the drawer' },
      add_connection = { key = 'A', desc = 'Add a connection' },
      delete = { key = 'd', desc = 'Delete selected item' },
      rename = { key = 'r', desc = 'Rename/edit buffer, connection, or saved query' },
      redraw = { key = 'R', desc = 'Redraw / refresh' },
      duplicate = { key = 'D', desc = 'Duplicate connection' },
      set_group = { key = 'G', desc = 'Add/remove connection to a group' },
      move_up = { key = '<C-Up>', desc = 'Move connection up (crosses group boundaries)' },
      move_down = { key = '<C-Down>', desc = 'Move connection down (crosses group boundaries)' },
      toggle_details = { key = 'H', desc = 'Toggle database details' },
      first_sibling = { key = '<C-k>', desc = 'Go to first sibling' },
      last_sibling = { key = '<C-j>', desc = 'Go to last sibling' },
      prev_sibling = { key = 'K', desc = 'Go to previous sibling' },
      next_sibling = { key = 'J', desc = 'Go to next sibling' },
      goto_parent = { key = '<C-p>', desc = 'Go to parent node' },
      goto_child = { key = '<C-n>', desc = 'Go to child node' },
    },
    query = {
      execute = { key = '<Leader>S', desc = 'Execute query (whole buffer / visual selection)', mode = { 'n', 'v' } },
      edit_bind_params = { key = '<Leader>E', desc = 'Edit bind parameters' },
      save_query = { key = '<Leader>W', desc = 'Save the current query (tmp buffers)' },
      cancel = { key = '<Leader>C', desc = 'Cancel the running query' },
    },
    results = {
      jump_foreign = { key = '<C-]>', desc = 'Jump to the foreign key table' },
      cell_value = {
        key = 'vic',
        desc = 'Select the cell value under the cursor',
        binds = { { mode = 'n', lhs = 'vic' }, { mode = 'o', lhs = 'ic' } },
      },
      yank_header = { key = 'yh', desc = 'Yank the result header as CSV' },
      toggle_layout = { key = '<Leader>R', desc = 'Toggle result layout (row / expanded)' },
      next_page = { key = ']', desc = 'Next page of results' },
      prev_page = { key = '[', desc = 'Previous page of results' },
      export = { key = '<Leader>X', desc = 'Export result to a file' },
    },
  },
}

-- Fixed (non-overridable) presentation metadata for `mappings`: the section
-- titles + their order in the help window, and the id order within each context
-- (used for both deterministic help rendering and keymap setup). Kept off
-- `defaults` so user overrides only touch keys/descriptions, never structure.
M.mapping_sections = {
  { group = 'sidebar', title = 'Sidebar' },
  { group = 'query', title = 'Query Buffer' },
  { group = 'results', title = 'DB Results' },
}

M.mapping_order = {
  sidebar = {
    'help',
    'toggle',
    'toggle_split',
    'quit',
    'add_connection',
    'delete',
    'rename',
    'redraw',
    'duplicate',
    'set_group',
    'move_up',
    'move_down',
    'toggle_details',
    'first_sibling',
    'last_sibling',
    'prev_sibling',
    'next_sibling',
    'goto_parent',
    'goto_child',
  },
  query = { 'execute', 'edit_bind_params', 'save_query', 'cancel' },
  results = { 'jump_foreign', 'cell_value', 'yank_header', 'toggle_layout', 'next_page', 'prev_page', 'export' },
}

---@private
-- The two function-valued options used the capitalized `g:Db_ui_*` globals.
local funcref_globals = {
  buffer_name_generator = 'Db_ui_buffer_name_generator',
  table_name_sorter = 'Db_ui_table_name_sorter',
}

---@private
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

---@private
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

---@private
-- Deep copy `t` as plain (unfrozen) tables, dropping any read-only metatable.
-- Backs the `__deepcopy` metamethod below so `vim.deepcopy(frozen)` yields a
-- mutable working copy (what e.g. `dadbod-ui.icons` wants) instead of tripping
-- the read-only guard.
local function plain_copy(t)
  if type(t) ~= 'table' then
    return t
  end
  local out = {}
  for k, v in pairs(t) do
    out[k] = plain_copy(v)
  end
  return out
end

---@private
-- Make `t` read-only in place, recursively: a write that ADDS a key (a typo or
-- a stray new field) at any depth raises. Kept in place -- values stay in the
-- table itself -- so reads, `pairs`/`ipairs` and `vim.tbl_*` keep working with
-- zero overhead; only a write traps. A `__deepcopy` metamethod keeps
-- `vim.deepcopy` working (returning an unfrozen copy). Lua's `__newindex` fires
-- only for ABSENT keys, so overwriting an existing field is not caught -- but
-- the resolved config is the shared SSOT (handed out by reference and read on
-- hot paths) and no module writes it, so this guards the realistic mistake
-- (adding / mis-spelling an option) without a proxy's enumeration cost.
---@generic T
---@param t T
---@return T
local function freeze(t)
  for _, v in pairs(t) do
    if type(v) == 'table' then
      freeze(v)
    end
  end
  return setmetatable(t, {
    __newindex = function(_, key)
      error(string.format("dadbod-ui: config is read-only (attempt to set '%s')", tostring(key)), 2)
    end,
    __deepcopy = plain_copy,
  })
end

--- Resolve effective config: defaults < `g:db_ui_*` globals < `opts`. The
--- returned table is frozen (see `freeze`): it is the session's shared config, so
--- accidental writes to it raise rather than silently corrupting every reader.
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
  return freeze(vim.tbl_deep_extend('force', out, opts or {}))
end

return M
