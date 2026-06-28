---@mod dadbod-ui.icons  Effective drawer icon set
---
--- Resolves the icon table the drawer renders with: a base set (plain unicode or
--- nerd-font glyphs) merged with the user's `icons` overrides. `expanded` /
--- `collapsed` may be given as a single string (applies to every node type) or a
--- per-type table. The `group` icon falls back to the `db` icon.

local M = {}

---@param nerd boolean
---@return DadbodUI.Icons
local function base_set(nerd)
  local exp, col = '▾', '▸'
  if not nerd then
    return {
      expanded = { db = exp, buffers = exp, saved_queries = exp, schemas = exp, schema = exp, tables = exp, table = exp, group = exp },
      collapsed = { db = col, buffers = col, saved_queries = col, schemas = col, schema = col, tables = col, table = col, group = col },
      saved_query = '*',
      new_query = '+',
      tables = '~',
      buffers = '»',
      group = '▪',
      add_connection = '[+]',
      connection_ok = '✓',
      connection_error = '✕',
    }
  end
  return {
    expanded = {
      db = exp .. ' 󰆼', buffers = exp .. ' ', saved_queries = exp .. ' ',
      schemas = exp .. ' ', schema = exp .. ' 󰙅', tables = exp .. ' 󰓱',
      table = exp .. ' ', group = exp .. ' 󰝰',
    },
    collapsed = {
      db = col .. ' 󰆼', buffers = col .. ' ', saved_queries = col .. ' ',
      schemas = col .. ' ', schema = col .. ' 󰙅', tables = col .. ' 󰓱',
      table = col .. ' ', group = col .. ' 󰉋',
    },
    saved_query = '  ',
    new_query = '  󰓰',
    tables = '  󰓫',
    buffers = '  ',
    group = '󰉋',
    add_connection = '  󰆺',
    connection_ok = '✓',
    connection_error = '✕',
  }
end

-- `value` may be a string (apply to every type) or a per-type table.
---@param set DadbodUI.Icons
---@param key 'expanded'|'collapsed'
---@param value string|table<string,string>
local function apply_toggle_override(set, key, value)
  if type(value) == 'string' then
    for t in pairs(set[key]) do
      set[key][t] = value
    end
  elseif type(value) == 'table' then
    set[key] = vim.tbl_extend('force', set[key], value)
  end
end

--- Build the effective icon table from resolved config.
---@param config DadbodUI.Config
---@return DadbodUI.Icons
function M.resolve(config)
  local icons = base_set(config.use_nerd_fonts)
  local user = vim.deepcopy(config.icons or {})
  for _, key in ipairs({ 'expanded', 'collapsed' }) do
    if user[key] ~= nil then
      apply_toggle_override(icons, key, user[key])
      user[key] = nil
    end
  end
  return vim.tbl_deep_extend('force', icons, user)
end

return M
