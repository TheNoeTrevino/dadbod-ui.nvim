-- Specs for the `User DBUIOpened` autocmd fired on a real drawer open.

local h = require('helper')

describe('User DBUIOpened', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('fires once on a real open, not when focusing an already-open drawer', function()
    d = h.make_drawer()
    local fired = 0
    local group = vim.api.nvim_create_augroup('dbui_opened_test', { clear = true })
    vim.api.nvim_create_autocmd('User', {
      group = group,
      pattern = 'DBUIOpened',
      callback = function()
        fired = fired + 1
      end,
    })
    d:open()
    d:open() -- already open: focuses without re-firing
    vim.api.nvim_del_augroup_by_id(group)
    assert.equals(1, fired)
  end)
end)
