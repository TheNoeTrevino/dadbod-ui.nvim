---@mod dadbod-ui.drawer.paint  The buffer-touching render half (lines + extmarks)
---
--- Standalone functions (no `self`): the drawer hands them a buffer, a node list
--- and the resolved icons. Kept apart from `drawer/content.lua` (the pure
--- `Node[]` builders) so the build/paint purity split stays visible in the file
--- layout.

local highlights = require('dadbod-ui.highlights')

---@class DadbodUI.DrawerPaint
---@field line_for fun(node: DadbodUI.Node): string
---@field apply_line_highlights fun(bufnr: integer, lnum: integer, hls: DadbodUI.Highlight[])
---@field paint fun(bufnr: integer, nodes: DadbodUI.Node[], icons: DadbodUI.Icons)

---@type DadbodUI.DrawerPaint
---@diagnostic disable-next-line: missing-fields
local M = {}

---@private
local INDENT = 2

--- The display string for a single node: indent + icon + separator + label. The
--- single source of truth for a rendered line, shared by the full `paint` and
--- the targeted `repaint_db_node` so an animated spinner frame lands identically
--- to a full render. Standalone (no `self`).
---@param node DadbodUI.Node
---@return string
function M.line_for(node)
  local indent = string.rep(' ', INDENT * node.level)
  local sep = node.icon ~= '' and ' ' or ''
  local trailer = node.loading_frame and (' ' .. node.loading_frame) or ''
  return indent .. node.icon .. sep .. node.label .. trailer
end

--- Apply the highlight ranges for ONE line (0-based `lnum`) as extmarks in the
--- `dadbod_ui` namespace. The caller is responsible for clearing the namespace
--- over the affected range first. Shared by the full `paint` and the single-line
--- `repaint_db_node` so an animated frame keeps the same colors as a full render.
---@param bufnr integer
---@param lnum integer
---@param hls DadbodUI.Highlight[]
---@return nil
function M.apply_line_highlights(bufnr, lnum, hls)
  for _, hl in ipairs(hls) do
    vim.api.nvim_buf_set_extmark(bufnr, highlights.NS, lnum, hl.col_start, {
      end_col = hl.col_end,
      hl_group = hl.group,
    })
  end
end

--- Paint a node list into `bufnr`: map each node to its display string (via
--- `line_for`), overwrite the buffer under a `modifiable` toggle, then re-apply
--- the per-node highlights as extmarks in the `dadbod_ui` namespace (cleared
--- first). The only render half that requires a buffer; the highlight ranges come
--- from the pure `highlights.highlights_for`, mirroring the `build_content`/
--- `paint` purity split. Standalone (no `self`) so the paint seam stays decoupled
--- from instance state; `icons` is threaded in for the connection ok/error glyph
--- lookup.
---@param bufnr integer
---@param nodes DadbodUI.Node[]
---@param icons DadbodUI.Icons
---@return nil
function M.paint(bufnr, nodes, icons)
  local lines = {}
  ---@type DadbodUI.Highlight[][]
  local line_hls = {}
  for i, node in ipairs(nodes) do
    local text = M.line_for(node)
    lines[i] = text
    line_hls[i] = highlights.highlights_for(node, text, icons)
  end

  local bo = vim.bo[bufnr]
  bo.modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  bo.modifiable = false

  vim.api.nvim_buf_clear_namespace(bufnr, highlights.NS, 0, -1)
  for i, hls in ipairs(line_hls) do
    M.apply_line_highlights(bufnr, i - 1, hls)
  end
end

return M
