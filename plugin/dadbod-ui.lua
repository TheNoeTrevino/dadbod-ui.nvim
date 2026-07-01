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

command('DBUIExportResult', function()
  require('dadbod-ui.export').export_interactive(vim.api.nvim_get_current_buf())
end, { nargs = 0, desc = 'Export the current query result to a file' })
