local h = require('helper')

-- Build a drawer over an instance seeded with injected connections. Offline
-- connector so expanding a connection never probes a real DB; the deferring
-- async_connector keeps the loading spinner observable between expand and
-- resolution.
local function make_drawer(g_dbs, overrides)
  return h.make_drawer({ g_dbs = g_dbs, config = overrides, connector = 'offline', async_connector = 'defer' })
end

describe('drawer: window', function()
  local d
  before_each(function()
    h.clean_ui()
  end)
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('opens a dbui window and reports open state', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    d:open()
    assert.is_true(d:is_open())
    assert.equals('dbui', vim.bo[d.bufnr].filetype)
    assert.equals('nofile', vim.bo[d.bufnr].buftype)
  end)

  it('closes the window', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    d:open()
    d:close()
    assert.is_false(d:is_open())
  end)

  it('toggles open/closed', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    d:toggle()
    assert.is_true(d:is_open())
    d:toggle()
    assert.is_false(d:is_open())
  end)
end)

describe('drawer: open failure', function()
  local d
  before_each(function()
    h.clean_ui()
  end)
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('does not clobber the user buffer when the split cannot open', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    -- A real user buffer with content in the focused (non-drawer) window.
    vim.cmd('enew')
    local user_win = vim.api.nvim_get_current_win()
    local user_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(user_buf, 0, -1, false, { 'important', 'user', 'data' })

    local notify = require('dadbod-ui.notifications')
    local msg
    local saved_err = notify.error
    notify.error = function(m)
      msg = m
    end
    -- Simulate E36 ("not enough room") by forcing the split command to fail.
    local real_cmd = vim.cmd
    vim.cmd = function(c)
      if type(c) == 'string' and c:find('new') then
        error('Vim(vertical):E36: Not enough room')
      end
      return real_cmd(c)
    end
    local ok = pcall(function()
      d:open()
    end)
    vim.cmd = real_cmd
    notify.error = saved_err

    assert.is_true(ok) -- no error bubbled to the caller
    assert.is_false(d:is_open())
    assert.is_not_nil(msg) -- notified the failure
    -- The user's window/buffer is untouched: same win, same buf, still a normal
    -- buffer with its original lines (not converted to a wiped nofile scratch).
    assert.equals(user_win, vim.api.nvim_get_current_win())
    assert.equals(user_buf, vim.api.nvim_get_current_buf())
    assert.equals('', vim.bo[user_buf].buftype)
    assert.same({ 'important', 'user', 'data' }, vim.api.nvim_buf_get_lines(user_buf, 0, -1, false))
  end)
end)

describe('drawer: render', function()
  local d
  before_each(function()
    h.clean_ui()
  end)
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('renders connections collapsed with the db icon', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    d:open()
    assert.equals('▸ dev', h.buf_lines(d.bufnr)[1])
  end)

  it('expands a connection to show New query, then collapses', function()
    d = make_drawer({ dev = 'postgres://h/dev' })
    d:open()
    vim.api.nvim_win_set_cursor(d.winid, { 1, 0 })
    d:toggle_line()
    -- New query renders immediately; the db node keeps its fold icon and trails
    -- the connection spinner until the deferred (blocking) connect resolves.
    local key = d.content[1].key_name
    assert.equals('  + New query', h.buf_lines(d.bufnr)[2])
    assert.equals('▾ dev ' .. require('dadbod-ui.spinners').dots[1], h.buf_lines(d.bufnr)[1])
    vim.wait(500, function()
      return not d.instance.dbs[key].loading
    end)
    assert.equals('▾ dev', h.buf_lines(d.bufnr)[1]) -- loading cleared (offline connector: not connected)
    d:toggle_line()
    assert.equals('▸ dev', h.buf_lines(d.bufnr)[1])
    assert.is_nil(h.buf_lines(d.bufnr)[2])
  end)
end)

describe('drawer: groups', function()
  local d
  before_each(function()
    h.clean_ui()
  end)
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  it('renders a group header with indented members', function()
    d = make_drawer({
      { name = 'pg', url = 'postgres://h/a', group = 'Local' },
    })
    d:open()
    local l = h.buf_lines(d.bufnr)
    assert.equals('▾ Local', l[1]) -- expand_groups default true
    assert.equals('  ▸ pg', l[2])
  end)

  it('collapsing a group hides its members', function()
    d = make_drawer({
      { name = 'pg', url = 'postgres://h/a', group = 'Local' },
    })
    d:open()
    vim.api.nvim_win_set_cursor(d.winid, { 1, 0 })
    d:toggle_line()
    local l = h.buf_lines(d.bufnr)
    assert.equals('▸ Local', l[1])
    assert.is_nil(l[2])
  end)
end)
