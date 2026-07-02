-- Generate doc/dadbod-ui.txt from the annotated sources.
-- Run with: nvim --headless -c "luafile scripts/minidoc.lua" -c "qa!"

local MiniDoc = require('mini.doc')
_G.MiniDoc = MiniDoc

MiniDoc.setup()

-- The sources use `local M = {}` as the module table, so MiniDoc infers help
-- tags/signatures named `M` / `M.foo` from the afterlines. Present them as the
-- plugin instead, and drop the noise `*M*` tag MiniDoc emits for the bare module
-- table (it also collides across files, which breaks `:helptags`). Compose with
-- MiniDoc's own write_pre (which trims the top delimiters).
local default_write_pre = MiniDoc.config.hooks.write_pre
MiniDoc.config.hooks.write_pre = function(lines)
  lines = default_write_pre(lines)
  local seen, out = {}, {}
  for _, line in ipairs(lines) do
    -- `M.foo` -> `dadbod-ui.foo` in both tags (`*..*`) and code spans (`` `..` ``).
    line = line:gsub('([%*`])M%.', '%1dadbod-ui.')
    -- Drop the bare module-table tag line (`        *M*`).
    if not line:match('^%s*%*M%*%s*$') then
      -- Defensive: keep every remaining help tag unique so `:helptags` succeeds.
      line = line:gsub('%*([^%*]+)%*', function(tag)
        if seen[tag] then
          return tag
        end
        seen[tag] = true
        return '*' .. tag .. '*'
      end)
      out[#out + 1] = line
    end
  end
  return out
end

-- Documentation order: the public facade first (intro + user-facing verbs), then
-- the configuration surface, then the commands.
local files = {
  'lua/dadbod-ui/init.lua', -- public API + setup()
  'lua/dadbod-ui/config.lua', -- configuration options
  'plugin/dadbod-ui.lua', -- commands
}

MiniDoc.generate(files, 'doc/dadbod-ui.txt')
