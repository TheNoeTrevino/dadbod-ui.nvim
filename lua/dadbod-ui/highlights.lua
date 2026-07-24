-- Drawer extmark highlighting (pure ranges + groups)
--
-- Highlighting is computed from the drawer's node tree rather than by matching
-- syntax regexes over the rendered text. The drawer splits rendering into
-- `build_content` (pure `Node[]`) and `paint` (the only buffer-touching half),
-- and every `Node` knows its `type`, `level`, `icon`, `label`. So
-- `highlights_for` computes the exact byte ranges to highlight straight from the
-- node + its painted line text -- pure, buffer-free, and unit-testable -- and
-- `paint` applies them as extmarks in a dedicated namespace. Groups are defined
-- once with `default = true` links so users can override them.

---@class DadbodUI.HighlightsModule
---@field NS integer  extmark namespace, cleared and repainted on every render
---@field define fun()
---@field color_group fun(hex: string): string
---@field winbar_color_group fun(hex: string): string
---@field paint_key fun(node: DadbodUI.Node): string
---@field highlights_for fun(node: DadbodUI.Node, line_text: string, icons: DadbodUI.Icons): DadbodUI.Highlight[]
---@field apply_line_highlights fun(bufnr: integer, lnum: integer, hls: DadbodUI.Highlight[], ns?: integer)

---@type DadbodUI.HighlightsModule
---@diagnostic disable-next-line: missing-fields
local M = {}

M.NS = vim.api.nvim_create_namespace('dadbod_ui')

--- Apply the highlight ranges for ONE line (0-based `lnum`) as extmarks -- in
--- the drawer's `dadbod_ui` namespace by default, or in `ns` (the explain tree
--- paints the same `DadbodUI.Highlight` shape into its own namespace). The
--- caller is responsible for clearing the namespace over the affected range
--- first.
---@param bufnr integer
---@param lnum integer
---@param hls DadbodUI.Highlight[]
---@param ns? integer  extmark namespace (default: `M.NS`)
---@return nil
function M.apply_line_highlights(bufnr, lnum, hls, ns)
  for _, hl in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(bufnr, ns or M.NS, lnum, hl.col_start, {
      end_col = hl.col_end,
      hl_group = hl.group,
    })
  end
end

---@private
-- Node type -> the highlight group for its icon column. Anything not listed
-- falls back to DadbodUIIcon (linked to Directory): most icon glyphs link to
-- Directory, and a few are singled out by icon name.
local ICON_GROUP = {
  query = 'DadbodUINewQuery', -- the New query (`+`) glyph -> Operator
  buffer = 'DadbodUIBuffers', -- open-buffer glyph -> Constant
  saved_query = 'DadbodUISavedQuery', -- saved-query glyph -> String
  table_helper = 'DadbodUITables', -- table-helper (tables) glyph -> Constant
  dbout = 'DadbodUITables', -- result-file (tables) glyph -> Constant
  add_connection = 'DadbodUIAddConnection',
}

--- Define the drawer's highlight groups. All are `default = true` links so a user
--- `:highlight`/`nvim_set_hl` override wins; only the connection ok/error colors
--- are concrete, and they are `&background`-aware. Safe to
--- call repeatedly (idempotent).
---@return nil
function M.define()
  ---@param name string
  ---@param link_to string
  local function link(name, link_to)
    vim.api.nvim_set_hl(0, name, { default = true, link = link_to })
  end
  link('DadbodUIIcon', 'Directory')
  link('DadbodUIAddConnection', 'Directory')
  link('DadbodUINewQuery', 'Operator')
  link('DadbodUISavedQuery', 'String')
  link('DadbodUIBuffers', 'Constant')
  link('DadbodUITables', 'Constant')
  link('DadbodUIHelp', 'Comment')
  link('DadbodUIHelpKey', 'String')
  link('DadbodUIConnectionSource', 'Comment')
  link('DadbodUIQueryTime', 'Comment') -- post-execute time/row summary (query-buffer ghost text)

  -- Explain-tree groups: structure dim, content plain, and a cold->hot ramp for
  -- a node's share of the plan (the renderer picks the tier; see
  -- explain/render.lua). All default links so themes/users override freely.
  link('DadbodUIExplainTree', 'NonText') -- branch glyphs + cell separators
  link('DadbodUIExplainOp', 'Statement') -- operation name (Seq Scan, Hash Join)
  link('DadbodUIExplainTarget', 'Constant') -- 'on orders o' / 'using users_pkey'
  link('DadbodUIExplainExpr', 'Comment') -- inline Filter/Cond/Key text
  link('DadbodUIExplainRows', 'Number')
  link('DadbodUIExplainSkew', 'WarningMsg') -- estimate-vs-actual misjudgment flag
  link('DadbodUIExplainCold', 'Comment')
  link('DadbodUIExplainMild', 'Normal')
  link('DadbodUIExplainWarm', 'WarningMsg')
  link('DadbodUIExplainHot', 'ErrorMsg')
  link('DadbodUIExplainSummary', 'Comment') -- the planning/execution header line

  local light = vim.o.background == 'light'
  vim.api.nvim_set_hl(0, 'DadbodUIConnectionOk', { default = true, fg = light and '#00AA00' or '#88FF88' })
  vim.api.nvim_set_hl(0, 'DadbodUIConnectionError', { default = true, fg = light and '#AA0000' or '#ff8888' })

  -- Result-window winbar blocks (tab-style, each a distinct background). `default`
  -- so a colorscheme or the user can override; the defaults give a powerline-ish
  -- look out of the box: page = accent, summary = muted, nav = action accent, fill
  -- = the bar's base (Neovim's WinBar) so the gaps/tail read as window background.
  local function hl(name, opts)
    opts.default = true
    vim.api.nvim_set_hl(0, name, opts)
  end
  if light then
    hl('DadbodUIWinbarPage', { fg = '#ffffff', bg = '#3d59a1' })
    hl('DadbodUIWinbar', { fg = '#1a1b26', bg = '#c4c8da' })
    hl('DadbodUIWinbarNav', { fg = '#ffffff', bg = '#33635c' })
    hl('DadbodUIWinbarExport', { fg = '#ffffff', bg = '#8f5e15' }) -- in-progress amber
  else
    hl('DadbodUIWinbarPage', { fg = '#1a1b26', bg = '#7aa2f7' })
    hl('DadbodUIWinbar', { fg = '#c0caf5', bg = '#3b4261' })
    hl('DadbodUIWinbarNav', { fg = '#1a1b26', bg = '#73daca' })
    hl('DadbodUIWinbarExport', { fg = '#1a1b26', bg = '#e0af68' }) -- in-progress amber
  end
  hl('DadbodUIWinbarFill', { link = 'WinBar' })
  -- Query-buffer connection winbar (`group/name`, right-aligned): a muted tab like
  -- the result summary, but its own group so users can recolour it independently.
  hl('DadbodUIWinbarConnection', { link = 'DadbodUIWinbar' })
end

-- The dynamic color groups already defined this "colorscheme generation":
-- `color_group`/`winbar_color_group` run in per-line paint paths (every colored
-- line of every repaint, every spinner frame), so the `nvim_set_hl` call is
-- made once per group and skipped thereafter. A `:colorscheme` wipes highlight
-- definitions, so the autocmd empties the memo and the next paint/winbar apply
-- re-defines whatever colors are actually on screen.
---@type table<string, boolean>
local defined = {}
vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('dadbod_ui_color_cache', { clear = true }),
  callback = function()
    defined = {}
  end,
})

---@private
--- Define `name` via `opts` once per colorscheme generation (see `defined`).
---@param name string
---@param opts vim.api.keyset.highlight
---@return string name
local function define_once(name, opts)
  if not defined[name] then
    defined[name] = true
    vim.api.nvim_set_hl(0, name, opts)
  end
  return name
end

--- The foreground highlight group for a user-assigned connection/group color
--- (issue #91): `DadbodUIColor_<rrggbb>`, defined with a concrete `fg` -- these
--- groups are derived from connections.json data, not the colorscheme. `hex`
--- must be a store-validated `#rrggbb` (dadbod-ui.connections normalizes case
--- and drops invalid values before a color ever reaches a node).
---@param hex string  `#rrggbb`, lowercase
---@return string
function M.color_group(hex)
  return define_once('DadbodUIColor_' .. hex:sub(2), { fg = hex })
end

--- The winbar block group for a user-assigned connection color (issue #91):
--- `DadbodUIWinbarColor_<rrggbb>`, the hex as BACKGROUND (a solid tab that
--- screams "prod" at the top of the query buffer, matching the other winbar
--- blocks) with black/white text picked by luminance so the name stays legible
--- on any color.
---@param hex string  `#rrggbb`, lowercase
---@return string
function M.winbar_color_group(hex)
  local name = 'DadbodUIWinbarColor_' .. hex:sub(2)
  if defined[name] then
    return name
  end
  local r = tonumber(hex:sub(2, 3), 16)
  local g = tonumber(hex:sub(4, 5), 16)
  local b = tonumber(hex:sub(6, 7), 16)
  -- Perceived luminance (ITU-R BT.601): dark text on light colors, and vice versa.
  local fg = (0.299 * r + 0.587 * g + 0.114 * b) > 140 and '#000000' or '#ffffff'
  return define_once(name, { fg = fg, bg = hex })
end

--- The incremental-paint identity of a node's HIGHLIGHTS: every node field
--- `highlights_for` reads that can change without changing the rendered line
--- text (a recolor, say, changes only the marks). The painter diffs
--- `(line text, paint_key)` pairs, so keeping this next to `highlights_for`
--- means a new highlight-affecting field gets added to both in one place --
--- omitted here, it would leave stale extmarks on lines whose text didn't move.
---@param node DadbodUI.Node
---@return string
function M.paint_key(node)
  return node.type .. '\0' .. node.icon .. (node.detail and '\0d' or '') .. (node.color and ('\0' .. node.color) or '')
end

--- The highlight ranges for one painted line. Pure: derives every byte column
--- from `node` and the already-rendered `line_text` (so multibyte nerd-font
--- glyphs are measured with `#`, never re-escaped into a regex). `icons` supplies
--- the connection ok/error glyphs to locate inside a db label.
---@param node DadbodUI.Node
---@param line_text string
---@param icons DadbodUI.Icons
---@return DadbodUI.Highlight[]
function M.highlights_for(node, line_text, icons)
  ---@type DadbodUI.Highlight[]
  local hls = {}

  -- Help lines: the whole `"…` line is Comment, and the leading key token
  -- (`o`/`S`/`<C-j>`…, the bit before ` - `) is String.
  if node.type == 'help' then
    if line_text:sub(1, 1) == '"' then
      hls[#hls + 1] = { group = 'DadbodUIHelp', col_start = 0, col_end = #line_text }
      local ks, ke = line_text:match('^"%s+()%S+()%s+%-')
      if ks ~= nil then
        hls[#hls + 1] = { group = 'DadbodUIHelpKey', col_start = ks - 1, col_end = ke - 1 }
      end
    end
    return hls
  end

  -- Icon column: the icon is the first non-space run, so locate it in the line
  -- (indent is spaces only) rather than re-deriving the indent width. The
  -- position is found once and shared with the color block below.
  local icon_start
  if node.icon ~= '' then
    icon_start = line_text:find(node.icon, 1, true)
    if icon_start ~= nil then
      hls[#hls + 1] = {
        group = ICON_GROUP[node.type] or 'DadbodUIIcon',
        col_start = icon_start - 1,
        col_end = icon_start - 1 + #node.icon,
      }
    end
  end

  -- A user-assigned connection/group color paints the leading `name_len` bytes
  -- of the label (the connection/group NAME -- never the status glyph or the
  -- `(…)` details suffix, which keep their own groups). The label starts right
  -- after the icon + its separator space; with no icon it starts at the first
  -- non-space (the indent is spaces only).
  if node.color ~= nil then
    local label_start
    if icon_start ~= nil then
      label_start = icon_start - 1 + #node.icon + 1
    elseif node.icon == '' then
      local s = line_text:find('%S')
      label_start = s ~= nil and s - 1 or nil
    end
    if label_start ~= nil then
      hls[#hls + 1] = {
        group = M.color_group(node.color),
        col_start = label_start,
        col_end = label_start + node.name_len,
      }
    end
  end

  -- Connection status glyphs appended to a db label.
  if node.type == 'db' then
    for glyph, group in pairs({
      [icons.connection_ok] = 'DadbodUIConnectionOk',
      [icons.connection_error] = 'DadbodUIConnectionError',
    }) do
      if glyph ~= '' then
        local s = line_text:find(glyph, 1, true)
        if s ~= nil then
          hls[#hls + 1] = { group = group, col_start = s - 1, col_end = s - 1 + #glyph }
        end
      end
    end
  end

  -- The trailing `(…)` detail suffix (a section's count, the `(scheme - source)`
  -- line under `H`, a group's `(Group)` tag) is dimmed. `node.detail` is stamped
  -- where the suffix is APPENDED (drawer/content.lua), so a node whose own name
  -- merely ends in `(...)` is never restyled.
  if node.detail then
    local ds, de = line_text:find('%([^()]*%)%s*$')
    if ds ~= nil then
      hls[#hls + 1] = { group = 'DadbodUIConnectionSource', col_start = ds - 1, col_end = de }
    end
  end

  return hls
end

return M
