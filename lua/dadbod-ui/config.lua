---@toc_entry Configuration
---@tag dadbod-ui-configuration
---@text
--- # Configuration ~
---
--- Options are passed to |dadbod-ui.setup()| as a table with snake_case keys
--- (the field surface is |DadbodUI.Config|). Every option has a sensible
--- default, so `setup()` is optional. See `M.defaults` in
--- `lua/dadbod-ui/config.lua` for the full default table.

---@class DadbodUI.ConfigModule
---@field defaults DadbodUI.Config
---@field contexts { group: string, title: string }[]
---@field builtin_actions table<string, table<string, string>>
---@field action_order table<string, string[]>
---@field resolve fun(opts?: DadbodUI.Opts): DadbodUI.Config

---@private
---@type DadbodUI.ConfigModule
---@diagnostic disable-next-line: missing-fields
local M = {}

--- Built-in defaults.
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
  env_variable_url = 'DBUI_URL',
  env_variable_name = 'DBUI_NAME',
  dotenv_variable_prefix = 'DB_UI_',
  ---@type table  icon overrides (see dadbod-ui.icons)
  icons = {},
  use_nerd_fonts = false,
  use_postgres_views = true,
  hide_schemas = {},
  is_oracle_legacy = false,
  debug = false,
  -- Backend for the connection picker (`require('dadbod-ui.api').pick()`).
  -- 'auto' tries Snacks.nvim, Telescope.nvim, then fzf-lua, falling back to
  -- vim.ui.select when none is installed; naming a backend uses it exclusively
  -- (warning when its plugin is missing), 'fallback' forces vim.ui.select.
  picker = 'auto',
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

  -- Notification presentation + routing. `disable_progress_bar` silences the
  -- schema-loading progress bar; `use_nvim_notify` routes through nvim-notify;
  -- `force_echo` always uses command-line echo; `disable_info` mutes info-level.
  notifications = {
    force_echo = false,
    disable_info = false,
    use_nvim_notify = false,
    disable_progress_bar = false,
  },

  -- The drawer/sidebar window.
  drawer = {
    width = 40,
    position = 'left',
    show_help = true,
    show_database_icon = false,
    expand_groups = true,
    -- Sections under an expanded connection, in render order. `procedures` lists
    -- the connection's stored procedures/functions (schema-supporting adapters
    -- nest them per schema); it renders only when the adapter supports routines
    -- and at least one exists, so it is invisible for e.g. sqlite.
    sections = { 'new_query', 'buffers', 'saved_queries', 'schemas', 'procedures' },
    -- Keymaps for the drawer buffer, `lhs -> action`. See the `keys` note above.
    keys = {
      ['?'] = 'help',
      ['o'] = 'toggle',
      ['<CR>'] = 'toggle',
      ['S'] = 'toggle_split',
      ['q'] = 'quit',
      ['A'] = 'add_connection',
      ['d'] = 'delete',
      ['r'] = 'rename',
      ['R'] = 'redraw',
      ['D'] = 'duplicate',
      ['G'] = 'set_group',
      ['<C-Up>'] = 'move_up',
      ['<C-Down>'] = 'move_down',
      ['H'] = 'toggle_details',
      ['<C-k>'] = 'first_sibling',
      ['<C-j>'] = 'last_sibling',
      ['K'] = 'prev_sibling',
      ['J'] = 'next_sibling',
      ['<C-p>'] = 'goto_parent',
      ['<C-n>'] = 'goto_child',
    },
  },

  -- SQL/query buffers.
  query = {
    default_query = 'SELECT * from "{table}" LIMIT 200;',
    execute_on_save = false,
    auto_execute_table_helpers = false,
    bind_param_pattern = ':\\w\\+',
    -- Show the connection a query buffer targets in a right-aligned `winbar` at
    -- the top of the buffer's window, formatted `group/name` (or just `name` when
    -- the connection is ungrouped). Follows the buffer into new splits; the
    -- `.dbout` result buffers (which own their winbar) and the drawer are untouched.
    show_buffer_connection = true,
    -- Keymaps for SQL/query buffers, `lhs -> action`. See the `keys` note above.
    keys = {
      ['<Leader>S'] = { 'execute', mode = { 'n', 'v' } },
      ['<Leader>E'] = 'edit_bind_params',
      ['<Leader>W'] = 'save_query',
      ['<Leader>C'] = 'cancel',
    },
  },

  -- `.dbout` result buffers.
  results = {
    page_size = 200,
    -- Split direction dadbod opens the `.dbout` result window in. dadbod itself
    -- decides horizontal vs. vertical off the command modifiers on `:DB`/`%DB`
    -- (see bridge.lua's execute functions), so this only steers which modifier we
    -- prefix. 'horizontal' is the default layout.
    layout = 'horizontal',
    list_sort = 'asc',
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
    -- Keymaps for `.dbout` result buffers, `lhs -> action`. See the `keys` note
    -- above. `cell_value` binds twice on purpose: `vic` selects in normal mode,
    -- `ic` is the operator-pending text object.
    keys = {
      ['<C-]>'] = 'jump_foreign',
      ['vic'] = { 'cell_value', mode = 'n' },
      ['ic'] = { 'cell_value', mode = 'o' },
      ['yh'] = 'yank_header',
      ['<Leader>R'] = 'toggle_layout',
      [']'] = 'next_page',
      ['['] = 'prev_page',
      ['<Leader>X'] = 'export',
    },
  },

  -- User-defined named actions, referenced by name from a context's `keys` map
  -- (e.g. `drawer = { keys = { Y = 'yank_url' } }`). Each is a function receiving
  -- a per-context action context (see `DadbodUI.*ActionContext`), or a
  -- `{ desc, fn }` table so the action also shows in the `?` help window.
  ---@type table<string, DadbodUI.Action>
  actions = {},
}

-- Fixed (non-overridable) presentation metadata for keymaps: the context titles
-- + their order in the help window, the built-in action descriptions, and the
-- action order within each context. Kept off `defaults` so user overrides only
-- touch `keys`/`actions`, never this structure. `dadbod-ui.mappings` renders the
-- help window and binds keys from `<context>.keys` against these tables.
M.contexts = {
  { group = 'drawer', title = 'Drawer' },
  { group = 'query', title = 'Query Buffer' },
  { group = 'results', title = 'DB Results' },
}

-- Built-in action id -> help description, per context. A key in a context's
-- `keys` map that names one of these binds the built-in handler supplied by the
-- owning module; any other name is looked up in `config.actions`.
M.builtin_actions = {
  drawer = {
    help = 'Toggle this help window',
    toggle = 'Open/Toggle selected item',
    toggle_split = 'Open selected item in a split',
    quit = 'Close the drawer',
    add_connection = 'Add a connection',
    delete = 'Delete selected item',
    rename = 'Rename/edit buffer, connection, or saved query',
    redraw = 'Redraw / refresh',
    duplicate = 'Duplicate connection',
    set_group = 'Add/remove connection to a group',
    move_up = 'Move connection up (crosses group boundaries)',
    move_down = 'Move connection down (crosses group boundaries)',
    toggle_details = 'Toggle database details',
    first_sibling = 'Go to first sibling',
    last_sibling = 'Go to last sibling',
    prev_sibling = 'Go to previous sibling',
    next_sibling = 'Go to next sibling',
    goto_parent = 'Go to parent node',
    goto_child = 'Go to child node',
  },
  query = {
    execute = 'Execute query (whole buffer / visual selection)',
    edit_bind_params = 'Edit bind parameters',
    save_query = 'Save the current query (tmp buffers)',
    cancel = 'Cancel the running query',
  },
  results = {
    jump_foreign = 'Jump to the foreign key table',
    cell_value = 'Select the cell value under the cursor',
    yank_header = 'Yank the result header as CSV',
    toggle_layout = 'Toggle result layout (row / expanded)',
    next_page = 'Next page of results',
    prev_page = 'Previous page of results',
    export = 'Export result to a file',
  },
}

-- Built-in action order within each context, for the help window. User actions
-- (bound in `keys` but absent here) render after these, sorted by name.
M.action_order = {
  drawer = {
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

--- Resolve effective config: defaults < `opts`. The returned table is frozen
--- (see `freeze`): it is the session's shared config, so accidental writes to
--- it raise rather than silently corrupting every reader.
---@param opts? DadbodUI.Opts  partial config overrides
---@return DadbodUI.Config
function M.resolve(opts)
  return freeze(vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {}))
end

return M
