-- Generate doc/dadbod-ui.txt from the annotated sources.
-- Run with: nvim --headless -c "luafile scripts/minidoc.lua" -c "qa!"

local MiniDoc = require('mini.doc')
_G.MiniDoc = MiniDoc

MiniDoc.setup()

-- Documentation order: the public facade first (intro + user-facing verbs), then
-- the configuration surface, then the commands.
local files = {
  'lua/dadbod-ui/init.lua', -- public API + setup()
  'lua/dadbod-ui/config.lua', -- configuration options
  'plugin/dadbod-ui.lua', -- commands
}

MiniDoc.generate(files, 'doc/dadbod-ui.txt')
