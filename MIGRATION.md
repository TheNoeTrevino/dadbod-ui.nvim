# Migrating from vim-dadbod-ui

<!--toc:start-->

- [Migrating from vim-dadbod-ui](#migrating-from-vim-dadbod-ui)
  - [What just works](#what-just-works)
    - [Connections](#connections)
  - [Globals -> opts](#globals-opts)
  - [Recreating the `:DBUI*` commands](#recreating-the-dbui-commands)
  - [Mappings](#mappings)
  <!--toc:end-->

This plugin is heavily inspired by [kristijanhusak/vim-dadbod-ui](https://github.com/kristijanhusak/vim-dadbod-ui)

The behavior is very familiar, but its written in lua and focused on a non-blocking UI.

One of the things you will need to do when migration, is migrating your configuration.

## What just works

### Connections

`g:db` and `g:dbs` are read exactly as before (they are the
vim-dadbod contract, not a dadbod-ui setting), so your connection list needs no
changes:

```lua
vim.g.dbs = {
  { name = "dev", url = "postgres://localhost/dev" },
  { name = "staging", url = "postgres://localhost/staging" },
}
```

- **`connections.json`.** The file dadbod-ui writes under `save_location` is the
  backwards compatible, so you can just copy the file right over.

- Environment / dotenv discovery. `DBUI_URL`, `DBUI_NAME`, and `DB_UI_*`
  `.env` keys work identically and are still configurable - see the table.

- Default keymaps. Every default key is the same (plus a few new ones). See
  [Mappings](#mappings).

## Globals -> opts

Instead of using global variables, the plugin is configured via its `.setup()` function.
If you use lazyvim, this is the `opts = {...` thing in the plugin spec. Here is the mapping between the configurations.

| vim-dadbod-ui global                  | dadbod-ui.nvim option                                               |
| ------------------------------------- | ------------------------------------------------------------------- |
| `g:db_ui_save_location`               | `save_location`                                                     |
| `g:db_ui_tmp_query_location`          | `tmp_query_location`                                                |
| `g:db_ui_table_helpers`               | `table_helpers`                                                     |
| `g:db_ui_env_variable_url`            | `env_variable_url`                                                  |
| `g:db_ui_env_variable_name`           | `env_variable_name`                                                 |
| `g:db_ui_dotenv_variable_prefix`      | `dotenv_variable_prefix`                                            |
| `g:db_ui_icons`                       | `icons`                                                             |
| `g:db_ui_use_nerd_fonts`              | `use_nerd_fonts`                                                    |
| `g:db_ui_use_postgres_views`          | `use_postgres_views`                                                |
| `g:db_ui_hide_schemas`                | `hide_schemas`                                                      |
| `g:db_ui_is_oracle_legacy`            | `is_oracle_legacy`                                                  |
| `g:db_ui_debug`                       | `debug`                                                             |
| `g:Db_ui_table_name_sorter`           | `table_name_sorter`                                                 |
| `g:Db_ui_buffer_name_generator`       | `buffer_name_generator`                                             |
| `g:db_ui_winwidth`                    | `drawer.width`                                                      |
| `g:db_ui_win_position`                | `drawer.position`                                                   |
| `g:db_ui_show_help`                   | `drawer.show_help`                                                  |
| `g:db_ui_expand_groups`               | `drawer.expand_groups`                                              |
| `g:db_ui_drawer_sections`             | `drawer.sections`                                                   |
| `g:db_ui_default_query`               | `query.default_query`                                               |
| `g:db_ui_execute_on_save`             | `query.execute_on_save`                                             |
| `g:db_ui_auto_execute_table_helpers`  | `query.auto_execute_table_helpers`                                  |
| `g:db_ui_bind_param_pattern`          | `query.bind_param_pattern`                                          |
| `g:db_ui_dbout_list_sort`             | `results.list_sort`                                                 |
| `g:db_ui_force_echo_notifications`    | `notifications.force_echo`                                          |
| `g:db_ui_disable_info_notifications`  | `notifications.disable_info`                                        |
| `g:db_ui_use_nvim_notify`             | `notifications.use_nvim_notify`                                     |
| `g:db_ui_disable_progress_bar`        | `notifications.disable_progress_bar`                                |
| `g:db_ui_disable_mappings`            | `drawer.keys = false`, `query.keys = false`, `results.keys = false` |
| `g:db_ui_disable_mappings_dbui`       | `drawer.keys = false`                                               |
| `g:db_ui_disable_mappings_sql`        | `query.keys = false`                                                |
| `g:db_ui_disable_mappings_javascript` | `query.keys = false`                                                |
| `g:db_ui_disable_mappings_dbout`      | `results.keys = false`                                              |

For example, if you configured this way:

```vim
let g:db_ui_winwidth = 50
let g:db_ui_win_position = 'right'
let g:db_ui_execute_on_save = 1
let g:db_ui_use_nerd_fonts = 1
let g:db_ui_force_echo_notifications = 1
```

You would now do this:

```lua
require("dadbod-ui").setup({
  use_nerd_fonts = true,
  drawer = { width = 50, position = "right" },
  query = { execute_on_save = true },
  notifications = { force_echo = true },
})
```

## Recreating the `:DBUI*` commands

This plugin doesn't come with out of the box user commands. It's an API focused plugin.

But, if you want to just use this plugin like `vim-dadbod-ui`, you can recreate the commands like this:

```lua
local api = require("dadbod-ui.api")
local function cmd(name, fn, opts) vim.api.nvim_create_user_command(name, fn, opts or {}) end

cmd("DBUI", function(a) api.open(a.mods) end)
cmd("DBUIToggle", api.toggle)
cmd("DBUIClose", api.close)
cmd("DBUIAddConnection", api.add_connection)
cmd("DBUIFindBuffer", api.buf.find)
cmd("DBUIRenameBuffer", api.buf.rename)
cmd("DBUILastQueryInfo", api.buf.last_query_info)
-- and a couple the vim-dadbod-ui doesn't have, but you might want:
cmd("DBUISwitchBuffer", function() api.buf.switch() end)
cmd("DBUICancelQuery", api.buf.cancel)
cmd("DBUIExportResult", function(a) api.dbout.export(a.args == "current" and "current" or "full") end, {
  nargs = "?",
  complete = function() return { "full", "current" } end,
})
```

## Mappings

The default keys are the same as vim-dadbod-ui, so nothing to relearn:

- Drawer: `o` / `<CR>` toggle, `S` split, `A` add, `d` delete, `r` rename,
  `R` redraw, `H` details, `q` quit, `K` / `J` prev/next sibling,
  `<C-k>` / `<C-j>` first/last sibling, `<C-p>` / `<C-n>` parent/child.
- Query buffers: `<Leader>S` execute (normal + visual), `<Leader>E` edit bind
  params, `<Leader>W` save query.
- Result buffers: `<C-]>` jump to foreign key, `vic` cell value, `yh` yank
  header, `<Leader>R` toggle layout.

On top of those you get a few new defaults: `?` (drawer help window), `D`
duplicate, `G` set group, `<C-Up>` / `<C-Down>` move connection, `<Leader>C`
cancel query, `]` / `[` result paging, and `<Leader>X` export.

To customize the mappings, see [Keymaps & actions](CONFIGURATION.md#keymaps--actions) for the documentation on how to do that.
