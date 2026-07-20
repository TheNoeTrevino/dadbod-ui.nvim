-- The buffer-touching render half (lines + extmarks)
--
-- Standalone functions (no `self`): the drawer hands them a buffer, a node list
-- and the resolved icons. Kept apart from `drawer/content.lua` (the pure
-- `Node[]` builders) so the build/paint purity split stays visible in the file
-- layout.

local highlights = require('dadbod-ui.highlights')

---@class DadbodUI.DrawerPaint
---@field line_for fun(node: DadbodUI.Node): string
---@field paint fun(bufnr: integer, nodes: DadbodUI.Node[], icons: DadbodUI.Icons, prev?: DadbodUI.Painted): DadbodUI.Painted

--- Snapshot of the last paint of a buffer: the rendered line texts plus each
--- line's highlight key -- the node fields `highlights_for` derives its ranges
--- from (`type` + `icon` + the `detail` flag + the `color`; the line text is its
--- only other input and is compared directly). Returned by `paint` and fed back into the next one to diff
--- against. `bufnr` makes a stale snapshot self-identifying: a recreated drawer
--- buffer is repainted from scratch by construction, with no reset for the
--- drawer to remember.
---@class DadbodUI.Painted
---@field bufnr integer
---@field lines string[]
---@field keys string[]

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

--- Paint a node list into `bufnr`: map each node to its display string (via
--- `line_for`), rewrite the buffer under a `modifiable` toggle, then apply the
--- per-node highlights as extmarks in the `dadbod_ui` namespace. The only render
--- half that requires a buffer; the highlight ranges come from the pure
--- `highlights.highlights_for`, mirroring the `build_content`/`paint` purity
--- split. Standalone (no `self`) so the paint seam stays decoupled from instance
--- state; `icons` is threaded in for the connection ok/error glyph lookup.
---
--- Incremental: given `prev` (the snapshot returned by the previous paint of
--- this buffer), only the span between the common prefix and common suffix is
--- range-replaced -- a toggle rewrites just the flipped node + its (in|de)dented
--- children, and an unchanged render touches nothing at all (no `set_lines`, no
--- extmark churn, no cursor jump from the BufEnter re-render). Extmarks outside
--- the replaced span shift with the edit, and highlight ranges are computed only
--- for the span (equal text + key guarantees an untouched line's marks are
--- already right).
---@param bufnr integer
---@param nodes DadbodUI.Node[]
---@param icons DadbodUI.Icons
---@param prev? DadbodUI.Painted
---@return DadbodUI.Painted painted  feed into the next paint of this buffer
function M.paint(bufnr, nodes, icons, prev)
  -- One pass filling two parallel arrays (`:each`, not one `:map():totable()`
  -- chain per array -- this runs on every keypress/BufEnter render).
  local lines, keys = {}, {}
  vim.iter(ipairs(nodes)):each(function(i, node)
    lines[i] = M.line_for(node)
    -- The color is part of the key: a recolor changes only the highlight, never
    -- the text, so without it the diff would skip the line and keep stale marks.
    keys[i] = node.type
      .. '\0'
      .. node.icon
      .. (node.detail and '\0d' or '')
      .. (node.color and ('\0' .. node.color) or '')
  end)
  local painted = { bufnr = bufnr, lines = lines, keys = keys }

  -- A snapshot of another buffer is stale. Its replacement doubles as the
  -- first-paint default: a fresh scratch buffer holds exactly one empty line
  -- and no extmarks, which is what this snapshot says.
  if prev == nil or prev.bufnr ~= bufnr then
    prev = { bufnr = bufnr, lines = { '' }, keys = { '' } }
  end

  --- Whether line `i` of the previous paint renders identically to line `j` of
  --- this one. Key equality covers highlight-only changes (e.g. a status-glyph
  --- group flip rides on the node's type/icon/text, never on hidden state).
  ---@param i integer
  ---@param j integer
  ---@return boolean
  local function same(i, j)
    return prev.lines[i] == lines[j] and prev.keys[i] == keys[j]
  end

  -- Longest common prefix, then longest common suffix over what remains (capped
  -- so the two never overlap when one render is a pure insertion/deletion
  -- inside the other).
  local prefix = 0
  local limit = math.min(#prev.lines, #lines)
  while prefix < limit and same(prefix + 1, prefix + 1) do
    prefix = prefix + 1
  end
  if prefix == #prev.lines and prefix == #lines then
    return painted -- identical render: leave the buffer untouched
  end
  local suffix = 0
  limit = limit - prefix
  while suffix < limit and same(#prev.lines - suffix, #lines - suffix) do
    suffix = suffix + 1
  end

  -- Replace buffer rows [prefix, #prev.lines - suffix) with the changed slice:
  -- clear the old span's extmarks first (marks outside it shift with the edit
  -- and stay valid), write, then highlight the new span.
  local old_end = #prev.lines - suffix
  local slice = (prefix == 0 and suffix == 0) and lines or vim.list_slice(lines, prefix + 1, #lines - suffix)
  vim.api.nvim_buf_clear_namespace(bufnr, highlights.NS, prefix, old_end)
  local bo = vim.bo[bufnr]
  bo.modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, prefix, old_end, false, slice)
  bo.modifiable = false
  for i = prefix + 1, #lines - suffix do
    highlights.apply_line_highlights(bufnr, i - 1, highlights.highlights_for(nodes[i], lines[i], icons))
  end
  return painted
end

return M
