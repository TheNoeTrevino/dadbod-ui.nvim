-- The plugin's identity, spelled out once
--
-- Every string that names the plugin lives here, split into two tiers:
--
-- Display strings use the product spelling `Dadbod-UI` and are safe to reword —
-- nothing programmatic matches on them.
--
-- Contract identifiers are matched by users' configs and third-party plugins,
-- or exist so a vim-dadbod-ui setup carries over unchanged (see MIGRATION.md):
-- renaming one is a breaking change, not a spelling tweak. The `DBUI`/`db_ui`
-- flavor is deliberate — DB stands for dadbod. Related contracts that live
-- elsewhere and must also never change: `b:db`, the `b:dbui_*` buffer vars,
-- `autoload/db_ui.vim`, `g:dbs`, the `.dbout` filetype.

---@class DadbodUI.ConstantsModule
---@field name string
---@field notify_title string
---@field statusline_prefix string
---@field drawer_filetype string
---@field drawer_opened_event string
---@field env_variable_url string
---@field env_variable_name string
---@field dotenv_variable_prefix string
---@field save_location string

---@type DadbodUI.ConstantsModule
return {
  -- Display strings.
  name = 'Dadbod-UI',
  notify_title = '[Dadbod-UI]',
  statusline_prefix = 'Dadbod-UI: ',

  -- Contract identifiers.
  -- The drawer filetype: statusline plugins key their dbui extensions on it.
  drawer_filetype = 'dbui',
  -- `autocmd User DBUIOpened` hooks, same event vim-dadbod-ui fires.
  drawer_opened_event = 'DBUIOpened',
  -- Connection-discovery defaults (config can override each): identical to
  -- vim-dadbod-ui's so existing env vars and .env files are picked up as-is.
  env_variable_url = 'DBUI_URL',
  env_variable_name = 'DBUI_NAME',
  dotenv_variable_prefix = 'DB_UI_',
  -- Default `save_location`
  -- vim-dadbod-ui's directory, so a migrating user's
  -- connections.json and saved queries are found without any pointing.
  save_location = '~/.local/share/db_ui',
}
