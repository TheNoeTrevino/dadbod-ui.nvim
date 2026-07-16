-- Specs for the incremental drawer repaint: render() diffs the new paint
-- against the previous snapshot and rewrites only the changed span, so an
-- unchanged render leaves the buffer (and its changedtick, extmarks and the
-- cursor) untouched, and a toggle only touches the flipped node's region.

local drawer_mod = require('dadbod-ui.drawer')
local ids = require('dadbod-ui.drawer.ids')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')
local highlights = require('dadbod-ui.highlights')

local function lines(d)
  return vim.api.nvim_buf_get_lines(d.bufnr, 0, -1, false)
end

local function tick(d)
  return vim.b[d.bufnr].changedtick
end

local function entry_named(d, name)
  for _, record in ipairs(d.instance.dbs_list) do
    if record.name == name then
      return d.instance.dbs[record.key_name]
    end
  end
end

describe('drawer repaint', function()
  local d

  before_each(function()
    local cfg = config.resolve({ save_location = '/tmp/dbui_repaint', drawer = { show_help = false } })
    local instance = state.new(cfg):populate({
      env = {},
      g_dbs = { a = 'postgres://h/a', b = 'postgres://h/b' },
      file_entries = {},
    })
    d = drawer_mod.new(instance)
    d.connector = function()
      return ''
    end
    d.async_connector = function(_, on_result)
      vim.schedule(function()
        on_result(true, '')
      end)
    end
    -- Seed introspected tables so the tree has real depth to expand into.
    for _, name in ipairs({ 'a', 'b' }) do
      local entry = entry_named(d, name)
      entry.schema_support = false
      entry.tables = { 'posts', 'users' }
    end
    d:open()
  end)

  after_each(function()
    d:close()
    d = nil
  end)

  it('does not touch the buffer when nothing changed', function()
    local before_lines, before_tick = lines(d), tick(d)
    d:render() -- e.g. the BufEnter re-render
    d:render()
    assert.equals(before_tick, tick(d))
    assert.same(before_lines, lines(d))
  end)

  it('keeps the cursor in place across a no-op render', function()
    vim.api.nvim_win_set_cursor(d.winid, { 2, 0 })
    d:render()
    assert.same({ 2, 0 }, vim.api.nvim_win_get_cursor(d.winid))
  end)

  it('expanding a node inserts its children without rewriting unrelated lines', function()
    local before = lines(d)
    d:set_expanded(ids.db(entry_named(d, 'a').key_name), true)
    d:render()
    local expanded = lines(d)
    assert.is_true(#expanded > #before)

    -- The buffer content after the incremental render matches what a full
    -- from-scratch paint of the same tree produces, line for line.
    for i, node in ipairs(d.content) do
      assert.equals(drawer_mod._line_for(node), expanded[i])
    end
    -- The untouched db node ('b') kept its exact pre-expand line text.
    local b_key = entry_named(d, 'b').key_name
    local b_node = vim.iter(d.content):find(function(n)
      return n.type == 'db' and n.key_name == b_key
    end)
    assert.is_true(vim.tbl_contains(before, expanded[b_node.index]))
  end)

  it('collapse restores the original buffer exactly', function()
    local collapsed = lines(d)
    local key = entry_named(d, 'a').key_name
    d:set_expanded(ids.db(key), true)
    d:render()
    d:set_expanded(ids.db(key), false)
    d:render()
    assert.same(collapsed, lines(d))
  end)

  it('re-applies highlights over the changed span (expanded children get extmarks)', function()
    local entry = entry_named(d, 'a')
    d:set_expanded(ids.db(entry.key_name), true)
    d:set_expanded(ids.section(entry.key_name, 'tables'), true)
    d:render()
    -- Every non-blank line carries at least one extmark after the incremental
    -- paint, including the freshly inserted children AND the shifted suffix.
    for i, text in ipairs(lines(d)) do
      if text ~= '' then
        local marks = vim.api.nvim_buf_get_extmarks(d.bufnr, highlights.NS, { i - 1, 0 }, { i - 1, -1 }, {})
        assert.is_true(#marks > 0, ('line %d (%s) lost its highlights'):format(i, text))
      end
    end
  end)

  it('drops the spinner frame once the loading marker clears', function()
    local entry = entry_named(d, 'b')
    entry.loading = true
    d:repaint_db_node(entry.key_name, '@@')
    assert.is_true(vim.iter(lines(d)):any(function(text)
      return text:find('@@', 1, true) ~= nil
    end))
    entry.loading = false
    d:render()
    for _, text in ipairs(lines(d)) do
      assert.is_nil(text:find('@@', 1, true))
    end
  end)

  it('repaints from scratch when the drawer buffer is recreated', function()
    local key = entry_named(d, 'a').key_name
    d:set_expanded(ids.db(key), true)
    d:render()
    local expanded = lines(d)
    -- close wipes the buffer; reopen must paint the fresh buffer fully rather
    -- than diff against the wiped one's snapshot.
    d:close()
    d:open()
    assert.same(expanded, lines(d))
  end)
end)
