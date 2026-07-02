---@toc_entry Commands
---@tag dadbod-ui-commands
---@text
--- # Commands ~
---
--- dadbod-ui.nvim provides the following user commands:
---
--- `:DBUI`                          Open the drawer
--- `:DBUIToggle`                    Toggle the drawer open/closed
--- `:DBUIClose`                     Close the drawer
--- `:DBUIAddConnection`             Add a connection interactively
--- `:DBUIFindBuffer`                Find/assign the query buffer for this db
--- `:DBUIRenameBuffer`              Rename the current query buffer
--- `:DBUILastQueryInfo`             Echo the last query and its runtime
--- `:DBUICancelQuery`               Cancel the running query for this buffer
--- `:DBUIExportResult [full|current]`  Export the current result to a file
---

-- Boot file: define user commands. Modules are required lazily inside the
-- callbacks so loading this plugin costs ~nothing until a command is run.

if vim.g.loaded_dadbod_ui then
  return
end
vim.g.loaded_dadbod_ui = true

local function command(name, fn, opts)
  vim.api.nvim_create_user_command(name, fn, opts or {})
end

command('DBUI', function(a)
  require('dadbod-ui').open(a.mods)
end, { nargs = 0, desc = 'Open the dadbod-ui drawer' })

command('DBUIToggle', function()
  require('dadbod-ui').toggle()
end, { nargs = 0, desc = 'Toggle the dadbod-ui drawer' })

command('DBUIClose', function()
  require('dadbod-ui').close()
end, { nargs = 0, desc = 'Close the dadbod-ui drawer' })

command('DBUIAddConnection', function()
  require('dadbod-ui').add_connection()
end, { nargs = 0, desc = 'Add a dadbod-ui connection' })

command('DBUIFindBuffer', function()
  require('dadbod-ui').find_buffer()
end, { nargs = 0, desc = 'Find/assign the dadbod-ui query buffer for this db context' })

command('DBUIRenameBuffer', function()
  require('dadbod-ui').rename_buffer()
end, { nargs = 0, desc = 'Rename the current dadbod-ui query buffer' })

command('DBUILastQueryInfo', function()
  require('dadbod-ui').print_last_query_info()
end, { nargs = 0, desc = 'Echo the last dadbod-ui query and its runtime' })

command('DBUICancelQuery', function()
  require('dadbod-ui').cancel_query()
end, { nargs = 0, desc = 'Cancel the running dadbod-ui query for this buffer' })

command('DBUIExportResult', function(a)
  -- `:DBUIExportResult current` exports only the on-screen page of a paginated
  -- result; with no arg (or anything else) it exports the whole query.
  local page_choice = a.args == 'current' and 'current' or 'full'
  require('dadbod-ui.export').export_interactive(vim.api.nvim_get_current_buf(), nil, page_choice)
end, {
  nargs = '?',
  complete = function()
    return { 'full', 'current' }
  end,
  desc = 'Export the current query result to a file',
})
