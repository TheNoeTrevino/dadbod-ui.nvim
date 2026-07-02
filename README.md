# dadbod-ui.nvim

A Neovim-native user interface for [tpope/vim-dadbod](https://github.com/tpope/vim-dadbod) written in lua.

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
    default_query = 'SELECT * from "{table}" LIMIT 200;',
    execute_on_save = false,                 -- run the query buffer on :w
    auto_execute_table_helpers = false,
    page_size = 200,                         -- rows per result page (pagination)
    env_variable_url = "DBUI_URL",
    env_variable_name = "DBUI_NAME",
    dotenv_variable_prefix = "DB_UI_",
    disable_progress_bar = false,
    notification_width = 40,
    winwidth = 40,
    win_position = "left",                   -- 'left' | 'right'
    result_layout = "horizontal",            -- 'horizontal' | 'vertical' .dbout split
    show_help = true,                        -- show the ? help hint in the drawer
    show_database_icon = false,
    use_nerd_fonts = false,
    icons = {},                              -- icon overrides (see dadbod-ui.icons)
    use_postgres_views = true,
    hide_schemas = {},                       -- Vim regexes; matching schemas are hidden
    bind_param_pattern = ":\\w\\+",
    drawer_sections = { "new_query", "buffers", "saved_queries", "schemas", "procedures" },
    expand_groups = true,                    -- groups start expanded
    dbout_list_sort = "asc",                 -- 'asc' | 'desc' order of the result list
    show_buffer_connection = true,           -- winbar showing the query buffer's connection
    force_echo_notifications = false,
    disable_info_notifications = false,
    use_nvim_notify = false,
    is_oracle_legacy = false,
    debug = false,

    -- Set any of these true to skip binding the built-in buffer-local mappings
    -- (bind your own via `keys`/autocmds instead). `disable_mappings` kills all.
    disable_mappings = false,
    disable_mappings_dbui = false,
    disable_mappings_dbout = false,
    disable_mappings_sql = false,
    disable_mappings_javascript = false,

    ---@type DadbodUI.BufferNameGenerator|nil
    buffer_name_generator = nil,             -- custom query-buffer name generator
    ---@type DadbodUI.TableNameSorter|nil
    table_name_sorter = nil,                 -- custom table-list sorter

    -- Inline post-execute feedback instead of dadbod's command-line echoes.
    query_time = {
      enabled = true,
      result_buffer = true,                  -- winbar summary on the .dbout window
      query_buffer = true,                   -- ghost text on the executed line
      show_row_count = true,
    },

    -- Native CLI result export (see :help dadbod-ui). Per-format sub-tables tune
    -- each formatter (dadbod-ui.export_formats).
    export = {
      prefer_native = true,                  -- use the CLI's own output when it can emit the format
      default_path = "",                     -- '' => cwd; directory the export prompt defaults to
      coerce_numbers = false,                -- emit numeric/boolean literals in json/sql
      csv = { delimiter = ",", header = true, quote = '"', null_string = "", line_feed_escape = "" },
      tsv = { line_feed_escape = "\\n" },
      json = { wrap_table_name = true, indent = "\t" },
    },

    -- Lifecycle hooks (see :help dadbod-ui). `on_connect` may return a rewritten
    -- url (e.g. swap a $password placeholder for a secret); the rest are observers.
    hooks = {},

    -- Keybindings, grouped by context. Each entry is `{ key, desc, mode? }`; set a
    -- key to 'none' to disable that action. Overrides deep-merge, so you can change
    -- a single mapping's `key` without redeclaring the rest.
    mappings = {
      sidebar = {
        help = { key = "?", desc = "Toggle this help window" },
        toggle = { key = { "o", "<CR>" }, desc = "Open/Toggle selected item" },
        toggle_split = { key = "S", desc = "Open selected item in a split" },
        quit = { key = "q", desc = "Close the drawer" },
        add_connection = { key = "A", desc = "Add a connection" },
        delete = { key = "d", desc = "Delete selected item" },
        rename = { key = "r", desc = "Rename/edit buffer, connection, or saved query" },
        redraw = { key = "R", desc = "Redraw / refresh" },
        duplicate = { key = "D", desc = "Duplicate connection" },
        set_group = { key = "G", desc = "Add/remove connection to a group" },
        move_up = { key = "<C-Up>", desc = "Move connection up (crosses group boundaries)" },
        move_down = { key = "<C-Down>", desc = "Move connection down (crosses group boundaries)" },
        toggle_details = { key = "H", desc = "Toggle database details" },
        first_sibling = { key = "<C-k>", desc = "Go to first sibling" },
        last_sibling = { key = "<C-j>", desc = "Go to last sibling" },
        prev_sibling = { key = "K", desc = "Go to previous sibling" },
        next_sibling = { key = "J", desc = "Go to next sibling" },
        goto_parent = { key = "<C-p>", desc = "Go to parent node" },
        goto_child = { key = "<C-n>", desc = "Go to child node" },
      },
      query = {
        execute = { key = "<Leader>S", desc = "Execute query (whole buffer / visual selection)", mode = { "n", "v" } },
        edit_bind_params = { key = "<Leader>E", desc = "Edit bind parameters" },
        save_query = { key = "<Leader>W", desc = "Save the current query (tmp buffers)" },
        cancel = { key = "<Leader>C", desc = "Cancel the running query" },
      },
      results = {
        jump_foreign = { key = "<C-]>", desc = "Jump to the foreign key table" },
        cell_value = { key = "vic", desc = "Select the cell value under the cursor" },
        yank_header = { key = "yh", desc = "Yank the result header as CSV" },
        toggle_layout = { key = "<Leader>R", desc = "Toggle result layout (row / expanded)" },
        next_page = { key = "]", desc = "Next page of results" },
        prev_page = { key = "[", desc = "Previous page of results" },
        export = { key = "<Leader>X", desc = "Export result to a file" },
      },
    },
  },
}
```

## Scripting examples

TODO

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md)
