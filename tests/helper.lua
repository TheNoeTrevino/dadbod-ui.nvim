-- Shared test helpers. The mini.test runner executes every spec in ONE Neovim
-- process (unlike plenary, which forked a fresh Neovim per file), so specs that
-- touch windows, buffers, modes or the dadbod-ui session singleton must start
-- from a known-clean state. `clean_ui()` restores that; call it from a spec's
-- `before_each` when the spec drives real windows/buffers.

local M = {}

--- Return to a single normal-mode window over a fresh scratch buffer, drop the
--- dadbod-ui session singleton, and wipe stray dbui/query/result buffers left by
--- earlier specs.
function M.clean_ui()
  -- Leave any insert/visual mode left over from a prior spec.
  vim.cmd('silent! stopinsert')
  if vim.fn.mode() ~= 'n' then
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)
  end
  -- Collapse to one window so `normal!`/feedkeys act on a predictable target.
  pcall(vim.cmd, 'silent! only!')
  -- Reset window-local options a prior spec may have left on the surviving
  -- window. dbout sets `foldmethod=expr`; a leftover fold makes linewise visual
  -- motions (`Vj`) swallow the whole fold, skewing selection-based specs.
  vim.wo.foldenable = false
  vim.wo.foldmethod = 'manual'
  vim.wo.foldexpr = '0'
  -- Reset the session state singleton (drops the cached instance + drawer).
  pcall(function()
    require('dadbod-ui.state').reset()
  end)
  -- Wipe leftover plugin buffers so a reopened query buffer can't reuse stale
  -- content; keep the current buffer.
  local cur = vim.api.nvim_get_current_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if b ~= cur and vim.api.nvim_buf_is_valid(b) then
      local ok, key = pcall(function()
        return vim.b[b].dbui_db_key_name
      end)
      local ft = vim.bo[b].filetype
      if ft == 'dbui' or ft == 'dbout' or (ok and key ~= nil) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
  end
end

return M
