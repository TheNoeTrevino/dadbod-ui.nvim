-- Specs for the explain-tree window: buffer contents mirror render.rows,
-- collapse toggling repaints and keeps the cursor on the node, the detail
-- float shows the raw node keys, and keymaps come from config.explain.keys.
-- Drives the real window (like the drawer specs), no DB involved.

local plan = require('dadbod-ui.explain.plan')
local state = require('dadbod-ui.state')
local tree = require('dadbod-ui.explain.tree')

local FIXTURE = [=[
[{"Plan": {
  "Node Type": "Sort",
  "Sort Key": ["t.b"],
  "Startup Cost": 10.0, "Total Cost": 12.0,
  "Plan Rows": 10, "Actual Rows": 10,
  "Actual Total Time": 100.0, "Actual Loops": 1,
  "Plans": [
    {"Node Type": "Seq Scan", "Relation Name": "things", "Alias": "t",
     "Rows Removed by Filter": 5,
     "Startup Cost": 0.0, "Total Cost": 9.0,
     "Plan Rows": 10, "Actual Rows": 10,
     "Actual Total Time": 90.0, "Actual Loops": 1}
  ]
}, "Execution Time": 101.0}]
]=]

local function open_fixture()
  local parsed = assert(plan.decode('postgres', FIXTURE))
  tree.open(parsed)
  return parsed
end

local function buf_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

describe('explain tree: window', function()
  before_each(function()
    require('helper').clean_ui()
    state.setup({ save_location = '/tmp/dbui_explain_tree', drawer = { show_help = false } })
  end)
  after_each(function()
    tree.close()
    state.reset()
  end)

  it('opens a scratch split painted with the rendered rows', function()
    open_fixture()
    local t = assert(tree.get())
    assert.equals('dbui-explain', vim.bo[t.bufnr].filetype)
    assert.equals('nofile', vim.bo[t.bufnr].buftype)
    assert.is_false(vim.bo[t.bufnr].modifiable)
    local lines = buf_lines(t.bufnr)
    assert.is_truthy(lines[1]:match('execution 101ms'))
    assert.is_truthy(lines[3]:match('^Sort'))
    assert.is_truthy(lines[4]:match('Seq Scan on things t'))
    -- Highlights land in the tree's own namespace.
    local marks = vim.api.nvim_buf_get_extmarks(t.bufnr, tree.NS, 0, -1, {})
    assert.is_true(#marks > 0)
  end)

  it('places the cursor on the root node row', function()
    open_fixture()
    local t = assert(tree.get())
    assert.equals(3, vim.api.nvim_win_get_cursor(t.winid)[1])
    local row = assert(tree.current_row())
    assert.equals('Sort', row.node.op)
  end)

  it('toggle_node collapses and re-expands the subtree under the cursor', function()
    open_fixture()
    local t = assert(tree.get())
    vim.api.nvim_win_set_cursor(t.winid, { 3, 0 }) -- the Sort root
    tree.toggle_node()
    local lines = buf_lines(t.bufnr)
    assert.equals(3, #lines) -- child row gone
    assert.is_truthy(lines[3]:match('▸ Sort'))
    -- Cursor stayed on the toggled node; toggling again restores the child.
    assert.equals(3, vim.api.nvim_win_get_cursor(t.winid)[1])
    tree.toggle_node()
    assert.is_truthy(buf_lines(t.bufnr)[4]:match('Seq Scan'))
  end)

  it('toggle_node is a no-op on leaves and the header', function()
    open_fixture()
    local t = assert(tree.get())
    for _, lnum in ipairs({ 1, 4 }) do -- header, leaf scan
      vim.api.nvim_win_set_cursor(t.winid, { lnum, 0 })
      tree.toggle_node()
      assert.equals(4, #buf_lines(t.bufnr))
    end
  end)

  it('node_details floats the raw adapter keys, Plans omitted', function()
    open_fixture()
    local t = assert(tree.get())
    vim.api.nvim_win_set_cursor(t.winid, { 4, 0 })
    tree.node_details()
    local float_buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
    local text = table.concat(buf_lines(float_buf), '\n')
    assert.is_truthy(text:match('Rows Removed by Filter: 5'))
    assert.is_truthy(text:match('Relation Name: things'))
    assert.is_falsy(text:match('Plans:'))
    vim.api.nvim_win_close(0, true)
  end)

  it('binds config.explain.keys on the tree buffer', function()
    open_fixture()
    local t = assert(tree.get())
    local bound = {}
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(t.bufnr, 'n')) do
      bound[map.lhs] = true
    end
    assert.is_true(bound['<CR>'])
    assert.is_true(bound['K'])
    assert.is_true(bound['q'])
    assert.is_true(bound['?'])
  end)

  it('re-opening replaces the tree in the same window', function()
    open_fixture()
    local first = assert(tree.get())
    open_fixture()
    local second = assert(tree.get())
    assert.equals(first.winid, second.winid)
    assert.same({}, second.collapsed) -- fresh view state per plan
  end)

  it('close drops the window and state', function()
    open_fixture()
    tree.close()
    assert.is_nil(tree.get())
    assert.is_nil(tree.current_row())
  end)
end)
