# dadbod-ui.nvim

A Neovim-native user interface for [tpope/vim-dadbod](https://github.com/tpope/vim-dadbod),
written in Lua.

Browse your connections, schemas, and tables in a drawer, fire off queries, and
read the results - all without leaving Neovim. It's a ground-up Lua rewrite of
[vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui): the same
familiar workflow, but API-first, deeply configurable, and typed to the teeth.

<!--toc:start-->

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
  - [Prefer `:DBUI*` commands?](#prefer-dbui-commands)
  - [Drawer](#drawer)
  - [Connections](#connections)
  - [Querying](#querying)
  - [Introspection](#introspection)
  - [Export](#export)
  - [Events](#events)
- [Migrating from vim-dadbod-ui](#migrating-from-vim-dadbod-ui)
- [Contributing](#contributing)
<!--toc:end-->

> [!NOTE]
> Considering migrating from [kristijanhusak/vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui)?
> Read the [migration guide](MIGRATION.md) for a tutorial

## Features

- A drawer for your databases
  - browse connections, schemas, tables, saved queries, and stored procedures
- Scratch & saved query buffers
  - SQL filetype so formatters and LSPs attach and work as expected
- Paginated result buffers
  - don't bomb your ran, keep things quick and responsive
- Inline query timing and row counts, right where you executed
- Native CLI export to CSV / TSV / JSON (and consistent Lua formatters as a fallback)
- A connection picker backed by `snacks.nvim`, `telescope.nvim`, or `fzf-lua`
- Fully remappable, per-buffer keymaps - and your own named actions
- Lifecycle hooks for scripting
- API focused: everything is reachable from `require('dadbod-ui.api')`, no
  commands to memorise

## Requirements

- Neovim >= 0.12
- [tpope/vim-dadbod](https://github.com/tpope/vim-dadbod) - the engine
- [snacks.nvim](https://github.com/folke/snacks.nvim) /
  [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) /
  [fzf-lua](https://github.com/ibhagwan/fzf-lua) - connection picker. _(optional)_
- [nvim-notify](https://github.com/rcarriga/nvim-notify) - prettier
  notifications. _(optional)_

## Installation

Here's a recommended setup for [lazy.nvim](https://github.com/folke/lazy.nvim)
that shows off the good stuff. Every option is optional - trim it to taste, or
drop `opts` entirely to run on defaults.

```lua
local prefix = "<localleader>d"
return {
  "TheNoeTrevino/dadbod-ui.nvim",
  dependencies = { "tpope/vim-dadbod" },
  -- No `:DBUI*` commands are shipped: drive everything from `require('dadbod-ui.api')`.
  -- These `keys` both define your mappings and lazy-load the plugin on first use.
  keys = {
    { prefix .. "d", function() require("dadbod-ui.api").toggle() end, desc = "Toggle Dadbod-UI" },
    { prefix .. "o", function() require("dadbod-ui.api").open() end, desc = "Open Dadbod-UI" },
    { prefix .. "f", function() require("dadbod-ui.api").buf.find() end, desc = "Dadbod-UI find buffer" },
    { prefix .. "a", function() require("dadbod-ui.api").add_connection() end, desc = "Dadbod-UI add connection" },
    { prefix .. "i", function() require("dadbod-ui.api").buf.last_query_info() end, desc = "Dadbod-UI last query info" },
  },
  ---@type DadbodUI.Config
  opts = {
    use_nerd_fonts = true,
    -- Pick a connection with your fuzzy finder of choice (api.pick())
    -- auto goes snacks -> telescope -> fzf -> `vim.ui.select`, picking the first available.
    picker = "snacks", -- "auto" | "snacks" | "telescope" | "fzf" | "fallback"

    drawer = {
      position = "right",
      show_database_icon = true,
      -- Each context's `keys` deep-merges over the defaults, so you only
      -- declare what you change. `false` unbinds a key; `keys = false` disables
      -- the whole context.
      keys = {
        Y = "yank_url", -- a custom action, defined below
      },
    },

    query = {
      execute_on_save = false,
    },

    -- Custom named actions, referenced by name from any context's `keys`. The
    -- drawer ctx carries `{ mode, bufnr, drawer, item, connection }`.
    actions = {
      yank_url = {
        desc = "Yank the connection URL",
        fn = function(ctx) vim.fn.setreg("+", ctx.connection.url) end,
      },
    },

    -- Lifecycle hooks. `resolve_bind_params` supplies bind-param values before
    -- dadbod-ui prompts; `on_connect` may rewrite the url (e.g. inject a secret).
    hooks = {
      resolve_bind_params = function(_names, _known)
        return { [":env"] = vim.env.APP_ENV }
      end,
    },
  },
}
```

Point it at your databases with `vim.g.dbs` (or dadbod's other connection
sources), then open the drawer:

```lua
vim.g.dbs = {
  { name = "dev", url = "postgres://localhost/dev" },
  { name = "staging", url = "postgres://localhost/staging" },
}
```

## Configuration

The block above is a curated slice. For the **complete option reference** -
every setting, its default, and how to use it, plus the deep dive on keymaps,
custom actions, and hooks - see [`CONFIGURATION.md`](CONFIGURATION.md).

## Usage

Everything the plugin does is reachable from Lua through
`require('dadbod-ui.api')`. Connections are addressed by **name**; when a name is
reused across groups, disambiguate with `"{group}/{name}"` or the full `key_name`
from `api.list()`.

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
api.buf.switch('prod')                               -- reassign the current query buffer
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

## Migrating from vim-dadbod-ui

Every `g:db_ui_*` global maps to a grouped `opts` field, your connections and
default keys carry over untouched, and the old `:DBUI*` commands are a few lines
away. See [`MIGRATION.md`](MIGRATION.md) for the full mapping.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md)
