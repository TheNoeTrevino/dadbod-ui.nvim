-- Generate doc/dadbod-ui.txt from the annotated sources.
-- Run with: nvim --headless -c "luafile scripts/minidoc.lua" -c "qa!"

local MiniDoc = require('mini.doc')
_G.MiniDoc = MiniDoc

MiniDoc.setup()

-- Documentation order: the public facade first (intro + user-facing verbs), then
-- the configuration surface.
local files = {
  'lua/dadbod-ui/init.lua', -- public API + setup()
  'lua/dadbod-ui/config.lua', -- configuration options
}

MiniDoc.generate(files, 'doc/dadbod-ui.txt')
