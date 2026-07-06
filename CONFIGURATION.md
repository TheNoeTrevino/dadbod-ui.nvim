# Configuration

Every option has a sensible default, so `setup()` (or a lazy `opts` table) is
completely optional - the plugin works out of the box. This document is the
_full_ reference: every option, its default, and how to use it.

Annotate your `opts` with `---@type DadbodUI.Config` for completion and hover
docs. Every field is optional, so you only ever declare what you want to change.

<!--toc:start-->
- [The default configuration](#the-default-configuration)
- [Option reference](#option-reference)
  - [Paths & discovery](#paths--discovery)
  - [Presentation](#presentation)
  - [Notifications](#notifications)
  - [Drawer](#drawer)
  - [Query buffers](#query-buffers)
  - [Result buffers](#result-buffers)
- [Keymaps & actions](#keymaps--actions)
- [Hooks](#hooks)
<!--toc:end-->

## The default configuration

This is the whole thing, verbatim from the defaults. Copy any slice of it into
your `opts` and tweak - you never need the whole block.

```lua
---@type DadbodUI.Config
opts = {
  save_location = "~/.local/share/db_ui",  -- where connections.json + saved queries live
  tmp_query_location = "",                 -- persist scratch query buffers here ('' = off)
  table_helpers = {},                      -- extra per-adapter helper templates
  table_helpers_order = { "List", "Columns", "Indexes", "Primary Keys", "Foreign Keys", "References" },
  env_variable_url = "DBUI_URL",           -- env var read as a connection url
  env_variable_name = "DBUI_NAME",         -- env var read as that connection's name
  dotenv_variable_prefix = "DB_UI_",       -- .env keys with this prefix become connections
  use_nerd_fonts = false,
  icons = {},                              -- icon overrides (see dadbod-ui.icons)
  use_postgres_views = true,
  hide_schemas = {},                       -- Vim regexes; matching schemas are hidden
  is_oracle_legacy = false,
  debug = false,
  picker = "auto",                         -- connection picker: 'auto'|'snacks'|'telescope'|'fzf'|'fallback'

  -- Notification presentation + routing.
  notifications = {
    force_echo = false,                    -- always use the command-line echo backend
    disable_info = false,                  -- mute info-level notifications
    use_nvim_notify = false,               -- route through nvim-notify
    disable_progress_bar = false,          -- silence the schema-loading progress bar
  },

  -- The drawer/sidebar window.
  drawer = {
    width = 40,
    position = "left",                     -- 'left' | 'right'
    show_help = true,                      -- show the ? help hint in the drawer
    show_database_icon = false,
    expand_groups = true,                  -- groups start expanded
    sections = { "new_query", "buffers", "saved_queries", "schemas", "procedures" },
    -- `lhs -> action`. See "Keymaps & actions" below.
    keys = {
      ["?"] = "help",                      -- Toggle this help window
      ["o"] = "toggle",                    -- Open/Toggle selected item
      ["<CR>"] = "toggle",                 -- Open/Toggle selected item
      ["S"] = "toggle_split",              -- Open selected item in a split
      ["q"] = "quit",                      -- Close the drawer
      ["A"] = "add_connection",            -- Add a connection
      ["d"] = "delete",                    -- Delete selected item
      ["r"] = "rename",                    -- Rename/edit buffer, connection, or saved query
      ["R"] = "redraw",                    -- Redraw / refresh
      ["D"] = "duplicate",                 -- Duplicate connection
      ["G"] = "set_group",                 -- Add/remove connection to a group
      ["<C-Up>"] = "move_up",              -- Move connection up (crosses group boundaries)
      ["<C-Down>"] = "move_down",          -- Move connection down (crosses group boundaries)
      ["H"] = "toggle_details",            -- Toggle database details
      ["<C-k>"] = "first_sibling",         -- Go to first sibling
      ["<C-j>"] = "last_sibling",          -- Go to last sibling
      ["K"] = "prev_sibling",              -- Go to previous sibling
      ["J"] = "next_sibling",              -- Go to next sibling
      ["<C-p>"] = "goto_parent",           -- Go to parent node
      ["<C-n>"] = "goto_child",            -- Go to child node
    },
  },

  -- SQL/query buffers.
  query = {
    default_query = 'SELECT * from "{table}" LIMIT 200;',
    execute_on_save = false,               -- run the query buffer on :w
    auto_execute_table_helpers = false,
    bind_param_pattern = ":\\w\\+",        -- Vim regex matching bind parameters
    show_buffer_connection = true,         -- winbar showing the query buffer's connection
    keys = {
      ["<Leader>S"] = { "execute", mode = { "n", "v" } }, -- Execute query (buffer / visual selection)
      ["<Leader>E"] = "edit_bind_params",  -- Edit bind parameters
      ["<Leader>W"] = "save_query",        -- Save the current query (tmp buffers)
      ["<Leader>C"] = "cancel",            -- Cancel the running query
    },
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
    -- Native CLI result export. Per-format sub-tables tune each formatter.
    export = {
      prefer_native = true,                -- use the CLI's own output when it can emit the format
      default_path = "",                   -- '' => cwd; directory the export prompt defaults to
      coerce_numbers = false,              -- emit numeric/boolean literals in json/sql
      csv = { delimiter = ",", header = true, quote = '"', null_string = "", line_feed_escape = "" },
      tsv = { line_feed_escape = "\\n" },
      json = { wrap_table_name = true, indent = "\t" },
    },
    keys = {
      ["<C-]>"] = "jump_foreign",          -- Jump to the foreign key table
      ["vic"] = { "cell_value", mode = "n" }, -- Select the cell value under the cursor
      ["ic"] = { "cell_value", mode = "o" },  -- ... as an operator-pending text object
      ["yh"] = "yank_header",              -- Yank the result header as CSV
      ["<Leader>R"] = "toggle_layout",     -- Toggle result layout (row / expanded)
      ["]"] = "next_page",                 -- Next page of results
      ["["] = "prev_page",                 -- Previous page of results
      ["<Leader>X"] = "export",            -- Export result to a file
    },
  },

  ---@type DadbodUI.BufferNameGenerator|nil
  buffer_name_generator = nil,             -- custom query-buffer name generator
  ---@type DadbodUI.TableNameSorter|nil
  table_name_sorter = nil,                 -- custom table-list sorter

  hooks = {},                              -- lifecycle hooks (see below)
  actions = {},                            -- custom named actions (see below)
}
```

## Option reference

### Paths & discovery

- `save_location` - directory holding `connections.json` and your saved queries.
  `~` is expanded.
- `tmp_query_location` - if set, scratch query buffers are persisted here and
  restored per-connection on the next session. `''` keeps them in-memory only.
- `env_variable_url` / `env_variable_name` - the environment variables read as a
  connection url and its name. Great for a `.envrc`/direnv-driven workflow.
- `dotenv_variable_prefix` - `.env` keys starting with this prefix are turned
  into connections (e.g. `DB_UI_STAGING=postgres://…` → a `staging` connection).
- `hide_schemas` - a list of Vim regexes; any schema matching one is hidden from
  the drawer.

> Connections themselves also come from `vim.g.db` / `vim.g.dbs` and dadbod's own
> mechanisms - see [`MIGRATION.md`](MIGRATION.md) if you are coming from
> vim-dadbod-ui.

### Presentation

- `use_nerd_fonts` - swap the ASCII glyphs for Nerd Font icons.
- `icons` - override individual glyphs. See `:help dadbod-ui.icons` for every key.
- `show_database_icon` (under `drawer`) - prefix each connection with a database
  glyph.
- `use_postgres_views` - include views alongside tables for Postgres.
- `is_oracle_legacy` - use the legacy Oracle introspection queries.

### Notifications

`notifications` controls how dadbod-ui talks to you:

- `force_echo` - always use the command-line `:echo` backend.
- `disable_info` - mute info-level notifications (errors still show).
- `use_nvim_notify` - route notifications through
  [nvim-notify](https://github.com/rcarriga/nvim-notify).
- `disable_progress_bar` - silence the progress bar shown while schemas load.

### Drawer

`drawer` is the sidebar tree:

- `width`, `position` (`'left'`/`'right'`) - window geometry.
- `show_help` - show the `?` hint at the top of the drawer.
- `expand_groups` - connection groups start expanded.
- `sections` - which nodes appear (and in what order) under an expanded
  connection: `new_query`, `buffers`, `saved_queries`, `schemas`, `procedures`.
  Drop any you don't want. `procedures` only renders for adapters that support
  stored routines and actually have some (so it's invisible for e.g. sqlite).
- `keys` - see [Keymaps & actions](#keymaps--actions).

### Query buffers

`query` covers your SQL scratch/saved buffers:

- `default_query` - the statement opened for a table's "New query". `{table}` is
  substituted with the table name.
- `execute_on_save` - run the whole buffer whenever you `:w` it.
- `auto_execute_table_helpers` - run a table helper immediately when you pick it,
  instead of just dropping its SQL into a buffer.
- `bind_param_pattern` - the Vim regex that recognises bind parameters (so
  `edit_bind_params` can prompt for them).
- `show_buffer_connection` - a right-aligned `group/name` winbar showing which
  connection the buffer targets.
- `keys` - see [Keymaps & actions](#keymaps--actions).

### Result buffers

`results` covers the `.dbout` window your query output lands in:

- `page_size` - rows per page. Paging is done with `LIMIT`/`OFFSET`, so large
  result sets stay responsive.
- `layout` - `'horizontal'` or `'vertical'` split for the result window.
- `list_sort` - `'asc'` / `'desc'` ordering of the result list.
- `query_time` - inline post-execute feedback instead of dadbod's echoes.
  `result_buffer` pins a summary to the `.dbout` winbar; `query_buffer` trails
  ghost text on the line you executed; `show_row_count` appends `· N rows`.
- `export` - native CLI result export. `prefer_native` writes the CLI's own
  output when it can emit the format directly; turn it off to force the
  consistent Lua formatters. The per-format sub-tables (`csv`/`tsv`/`json`) tune
  each formatter. See `:help dadbod-ui` for the full export story.
- `keys` - see [Keymaps & actions](#keymaps--actions).

## Keymaps & actions

Every buffer context (`drawer`, `query`, `results`) owns a `keys` map. It is
`lhs -> action`, where an action is:

- a **built-in id** (`"toggle"`, `"execute"`, `"next_page"`, … - the strings in
  the default config above),
- a **name from your `actions` table** (a custom action, see below), or
- a `{ "<action>", mode = ... }` table when you need a specific mode (e.g. a
  visual-mode binding, or an operator-pending text object).

`keys` **deep-merges over the defaults**, so you only declare what you change:

```lua
opts = {
  drawer = {
    keys = {
      d = false,        -- unbind the default delete key
      x = "delete",     -- rebind delete to `x`
      Y = "yank_url",   -- bind a custom action (defined in `actions`)
    },
  },
  results = {
    keys = false,       -- disable EVERY result-buffer mapping
  },
}
```

Set a single key to `false` to unbind it, or set a whole context's `keys = false`
to disable all of that context's mappings.

### Custom actions

Define named actions in the top-level `actions` table, then reference them by
name from any context's `keys`. Each action receives a **per-context action
context**:

- **drawer** → `{ mode, bufnr, drawer, item, connection }`
- **query** → `{ mode, bufnr, connection, query }`
- **results** → `{ mode, bufnr, connection }`

A bare function is fine; use the `{ desc, fn }` form so the action also shows up
in the `?` help window:

```lua
opts = {
  actions = {
    yank_url = {
      desc = "Yank the connection URL",
      fn = function(ctx) vim.fn.setreg("+", ctx.connection.url) end,
    },
  },
  drawer = { keys = { Y = "yank_url" } },
}
```

## Hooks

`hooks` is a table of optional lifecycle callbacks fired around connect / execute
/ cancel. A throwing hook is caught and reported - it never aborts the underlying
operation.

- `on_connect(event)` - a **transform**: returning a string rewrites the
  connection url before connecting (e.g. swap a `$password` placeholder for a
  real secret).
- `resolve_bind_params(names, known)` - supply bind-parameter values before
  dadbod-ui prompts for them. Return a table for the ones you know; the rest fall
  back to prompts.
- The `on_*_post` / execute / cancel siblings are **observers**.

```lua
opts = {
  hooks = {
    resolve_bind_params = function(names, known)
      -- names: { ":id", ":env" }
      return { [":env"] = vim.env.APP_ENV } -- ':id' still gets prompted
    end,
    on_connect = function(event)
      return (event.url:gsub("%$password", vim.env.PGPASSWORD))
    end,
  },
}
```

> For runtime observation with **many** listeners (rather than the single-slot
> hooks here), use the event bus: `require('dadbod-ui.api').on(...)`. See the
> Events section of the [README](README.md).

See `:help dadbod-ui` for the complete annotated type surface.
