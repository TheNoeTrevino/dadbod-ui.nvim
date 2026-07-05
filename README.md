# dadbod-ui.nvim

A Neovim-native user interface for [tpope/vim-dadbod](https://github.com/tpope/vim-dadbod) written in lua.

Requires Neovim >= 0.12.

## Installation & full configuration ([lazy.nvim](https://github.com/folke/lazy.nvim))

```lua
local prefix = "<localleader>d"
return {
  "TheNoeTrevino/dadbod-ui.nvim",
  dependencies = { "tpope/vim-dadbod" },
  cmd = { "DBUI", "DBUIToggle", "DBUIAddConnection", "DBUIFindBuffer" },
  keys = {
    { prefix .. "d", function() require("dadbod-ui.api").toggle() end, desc = "Toggle DBUI" },
    { prefix .. "o", function() require("dadbod-ui.api").open() end, desc = "Open DBUI" },
    { prefix .. "f", function() require("dadbod-ui.api").find_buffer() end, desc = "DBUI find buffer" },
    { prefix .. "a", function() require("dadbod-ui.api").add_connection() end, desc = "DBUI add connection" },
    { prefix .. "i", function() require("dadbod-ui.api").last_query_info() end, desc = "DBUI last query info" },
  },
  -- default config
  ---@type DadbodUI.Config
  opts = {
    save_location = "~/.local/share/db_ui",  -- where connections.json + saved queries live
    tmp_query_location = "",                 -- persist scratch query buffers here ('' = off)
    table_helpers = {},                      -- extra per-adapter helper templates
    table_helpers_order = { "List", "Columns", "Indexes", "Primary Keys", "Foreign Keys", "References" },
    env_variable_url = "DBUI_URL",
    env_variable_name = "DBUI_NAME",
    dotenv_variable_prefix = "DB_UI_",
    use_nerd_fonts = false,
    icons = {},                              -- icon overrides (see dadbod-ui.icons)
    use_postgres_views = true,
    hide_schemas = {},                       -- Vim regexes; matching schemas are hidden
    is_oracle_legacy = false,
    debug = false,

    -- Notification presentation + routing.
    notifications = {
      force_echo = false,
      disable_info = false,
      use_nvim_notify = false,
      disable_progress_bar = false,
    },

    -- The drawer/sidebar window.
    drawer = {
      width = 40,
      position = "left",                     -- 'left' | 'right'
      show_help = true,                      -- show the ? help hint in the drawer
      show_database_icon = false,
      expand_groups = true,                  -- groups start expanded
      sections = { "new_query", "buffers", "saved_queries", "schemas", "procedures" },
    },

    -- SQL/query buffers.
    query = {
      default_query = 'SELECT * from "{table}" LIMIT 200;',
      execute_on_save = false,               -- run the query buffer on :w
      auto_execute_table_helpers = false,
      bind_param_pattern = ":\\w\\+",
      show_buffer_connection = true,         -- winbar showing the query buffer's connection
    },

    -- .dbout result buffers.
    results = {
      page_size = 200,                       -- rows per result page (pagination)
      layout = "horizontal",                 -- 'horizontal' | 'vertical' .dbout split
      list_sort = "asc",                     -- 'asc' | 'desc' order of the result list
      -- Inline post-execute feedback instead of dadbod's command-line echoes.
      query_time = {
        enabled = true,
        result_buffer = true,                -- winbar summary on the .dbout window
        query_buffer = true,                 -- ghost text on the executed line
        show_row_count = true,
      },
      -- Native CLI result export (see :help dadbod-ui). Per-format sub-tables tune
      -- each formatter (dadbod-ui.export_formats).
      export = {
        prefer_native = true,                -- use the CLI's own output when it can emit the format
        default_path = "",                   -- '' => cwd; directory the export prompt defaults to
        coerce_numbers = false,              -- emit numeric/boolean literals in json/sql
        csv = { delimiter = ",", header = true, quote = '"', null_string = "", line_feed_escape = "" },
        tsv = { line_feed_escape = "\\n" },
        json = { wrap_table_name = true, indent = "\t" },
      },
    },

    ---@type DadbodUI.BufferNameGenerator|nil
    buffer_name_generator = nil,             -- custom query-buffer name generator
    ---@type DadbodUI.TableNameSorter|nil
    table_name_sorter = nil,                 -- custom table-list sorter

    -- Lifecycle hooks (see :help dadbod-ui). `on_connect` may return a rewritten
    -- url (e.g. swap a $password placeholder for a secret); `resolve_bind_params`
    -- supplies bind-param values before prompting; the `on_*` hooks are observers.
    hooks = {
      -- resolve_bind_params = function(names, known)  -- names: { ':id', ':env' }
      --   return { [':env'] = vim.env.APP_ENV }       -- rest fall back to prompts
      -- end,
    },

    -- Custom named actions, referenced by name from a context's `keys` map (see
    -- below). Each receives a per-context action context: the drawer gets
    -- `{ mode, bufnr, drawer, item, connection }`, query/results get
    -- `{ mode, bufnr, connection, query? }`. Use `{ desc, fn }` to also show the
    -- action in the `?` help window.
    actions = {
      -- yank_url = {
      --   desc = "Yank the connection URL",
      --   fn = function(ctx) vim.fn.setreg("+", ctx.connection.url) end,
      -- },
    },
  },
}
```

### Keymaps

Each context (`drawer`, `query`, `results`) carries a `keys` map of `lhs -> action`.
An action is a built-in id (e.g. `"delete"`, `"execute"`, `"next_page"`), a name from
your `actions` table, or `{ "<action>", mode = { "n", "v" } }` to bind specific modes.
Set a key to `false` to disable it, or set a whole context's `keys` to `false` to unbind
everything there. Overrides deep-merge, so you only declare what you change:

```lua
opts = {
  drawer = {
    keys = {
      d = false, -- unbind the default delete key
      x = "delete", -- rebind delete to `x`
      Y = "yank_url", -- bind a custom action (from `actions` above)
    },
  },
  results = {
    keys = false, -- no result-buffer keymaps at all
  },
}
```

The built-in actions are the defaults shown in the `?` help window: the drawer's
`help`, `toggle`, `toggle_split`, `quit`, `add_connection`, `delete`, `rename`,
`redraw`, `duplicate`, `set_group`, `move_up`, `move_down`, `toggle_details`,
`first_sibling`, `last_sibling`, `prev_sibling`, `next_sibling`, `goto_parent`,
`goto_child`; the query buffer's `execute`, `edit_bind_params`, `save_query`, `cancel`;
and the result buffer's `jump_foreign`, `cell_value`, `yank_header`, `toggle_layout`,
`next_page`, `prev_page`, `export`.

## Scripting examples

Everything the plugin does is reachable from Lua through `require('dadbod-ui.api')`
- a thin, stable facade with no default mappings, so you can wire your own. There
are no `:DBUI*` commands you can't script.

Connections are addressed by **name**. When a name is reused across groups,
disambiguate with `"{group}/{name}"` or the full `key_name` from `api.list()`.

```lua
local api = require('dadbod-ui.api')
```

### Drawer

```lua
api.open()            -- open the drawer (accepts mods, e.g. api.open('tab'))
api.toggle()
api.close()
api.reveal('dev')     -- open + expand + focus a connection (introspects it)
api.refresh('dev')    -- re-scan schemas/tables + reload saved queries
```

### Connections

```lua
for _, c in ipairs(api.list()) do print(c.group, c.name, c.is_connected) end
local info = api.info('analytics/prod')  -- url, scheme, tables, schemas, connected…
api.is_connected('dev')

-- Manage the connections.json store (non-interactive; file-backed conns only):
api.add({ name = 'dev', url = 'postgres://localhost/dev', group = 'local' })
api.rename('dev', 'development')
api.duplicate('development', 'dev-copy', 'scratch')  -- clone into another group
api.set_group('dev-copy', 'archive')                 -- '' to ungroup
api.move('development', 'up')                         -- reorder among siblings
api.remove('dev-copy')

-- Live connection lifecycle:
api.connect('dev', function(ok, err) end)  -- async; no-op if already connected
api.disconnect('dev')                      -- drop the live handle (next use reconnects)
```

### Querying

```lua
-- Async, returns raw adapter output lines; never opens a result window:
api.query('dev', 'select count(*) from users', function(rows, err)
  if err then return vim.notify(err, vim.log.levels.ERROR) end
  vim.print(rows)
end)

local rows, err = api.query_sync('dev', 'select 1')  -- blocking dual for scripts
api.execute('dev', 'select * from users')            -- run through :DB, open .dbout
api.open_query('dev')                                -- fresh scratch buffer bound to dev
api.switch_buffer('prod')                            -- reassign the current query buffer
```

### Introspection

```lua
api.tables('dev', function(tables) vim.print(tables) end)
api.schemas('dev', function(schemas) vim.print(schemas) end)
api.introspect('dev', function(data) vim.print(data.tables, data.schemas, data.routines) end)
```

### Export

```lua
api.export({ name = 'dev', sql = 'select * from users', format = 'csv', path = '/tmp/users.csv' })
```

### Events

Observe the connect / execute / cancel lifecycle at runtime. Unlike the single-slot
`hooks` in `setup{}`, any number of listeners can subscribe and they compose with a
configured hook rather than replacing it (listeners are observers - an `on_connect`
listener can't rewrite the url).

```lua
local handle = api.on('on_execute_query_post', function(ev)
  vim.notify(('query finished in %ss (exit %s)'):format(ev.runtime, ev.exit_status))
  -- ev.rows() reads the result lazily; ev.query is the executed statement
end)

api.off(handle)  -- unsubscribe
```

Events: `on_connect`, `on_connect_post`, `on_execute_query`, `on_execute_query_post`,
`on_cancel_query`, `on_cancel_query_post`.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md)
