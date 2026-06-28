local drawer_mod = require('dadbod-ui.drawer')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')
local connections = require('dadbod-ui.connections')
local notifications = require('dadbod-ui.notifications')

-- A drawer over an instance seeded with injected sources. `save_location`
-- points at a real temp dir so connections.json round-trips on disk.
local function make_drawer(opts)
  opts = opts or {}
  local cfg = config.resolve({
    save_location = opts.save_location,
    show_help = false,
    disable_info_notifications = false,
  })
  local instance = state.new(cfg):populate({
    env = {},
    g_dbs = opts.g_dbs or {},
    file_entries = opts.file_entries or {},
  })
  local d = drawer_mod.new(instance)
  -- Drive prompts from a queue and confirmations from a fixed answer.
  local queue = opts.inputs or {}
  local idx = 0
  d.input = function(_, on_confirm)
    idx = idx + 1
    on_confirm(queue[idx])
  end
  d.confirm = function()
    if opts.confirm == nil then
      return true
    end
    return opts.confirm
  end
  return d
end

-- Find a populated entry by connection name.
local function entry_named(d, name)
  for _, r in ipairs(d.instance.dbs_list) do
    if r.name == name then
      return d.instance.dbs[r.key_name]
    end
  end
  return nil
end

local function stored(path)
  return connections.read_file(path)
end

describe('connection management: add', function()
  local d, dir
  before_each(function()
    dir = vim.fn.tempname()
  end)
  after_each(function()
    if d then
      d:close()
      d = nil
    end
    vim.fn.delete(dir, 'rf')
  end)

  it('adds a connection: writes connections.json and shows it in the drawer', function()
    d = make_drawer({ save_location = dir, inputs = { 'sqlite:' .. dir .. '/qa.db', 'qa' } })
    d:open()
    d:add_connection()

    local file = stored(d.instance.connections_path)
    assert.equals(1, #file)
    assert.equals('qa', file[1].name)
    assert.is_not_nil(entry_named(d, 'qa'))
    assert.is_truthy(vim.tbl_contains(vim.api.nvim_buf_get_lines(d.bufnr, 0, -1, false), '▸ qa'))
  end)

  it('rejects a duplicate name and writes nothing', function()
    connections.write_file(dir .. '/connections.json', { { name = 'qa', url = 'sqlite:' .. dir .. '/qa.db' } })
    d = make_drawer({ save_location = dir, inputs = { 'sqlite:' .. dir .. '/other.db', 'qa' } })
    d:add_connection()

    local file = stored(d.instance.connections_path)
    assert.equals(1, #file)
    assert.equals('sqlite:' .. dir .. '/qa.db', file[1].url) -- untouched
    assert.is_truthy(notifications.get_last_msg():find('already exists'))
  end)

  it('rejects a blank name and writes nothing', function()
    d = make_drawer({ save_location = dir, inputs = { 'sqlite:' .. dir .. '/qa.db', '   ' } })
    d:add_connection()
    assert.equals(0, #stored(d.instance.connections_path))
    assert.is_truthy(notifications.get_last_msg():find('valid name'))
  end)

  it('refuses with no save location set', function()
    d = make_drawer({ save_location = '', inputs = { 'sqlite:/x.db', 'x' } })
    d:add_connection()
    assert.is_truthy(notifications.get_last_msg():find('save location'))
  end)

  it('refuses to overwrite a corrupt connections.json on add', function()
    vim.fn.mkdir(dir, 'p')
    local path = dir .. '/connections.json'
    vim.fn.writefile({ '{ corrupt not an array' }, path)
    d = make_drawer({ save_location = dir, inputs = { 'sqlite:' .. dir .. '/qa.db', 'qa' } })
    d:add_connection()

    -- the original corrupt bytes are still on disk, untouched
    assert.equals('{ corrupt not an array', vim.fn.readfile(path)[1])
    assert.is_nil(entry_named(d, 'qa'))
    assert.is_truthy(notifications.get_last_msg():find('refusing to overwrite'))
  end)

  it('makes the empty-state Add connection node functional', function()
    d = make_drawer({ save_location = dir, inputs = { 'sqlite:' .. dir .. '/qa.db', 'qa' } })
    d:open()
    -- with no connections, line 2 is the Add connection node
    vim.api.nvim_win_set_cursor(d.winid, { 2, 0 })
    assert.equals('add_connection', d:get_current_item().type)
    d:toggle_line()
    assert.is_not_nil(entry_named(d, 'qa'))
  end)
end)

describe('connection management: rename', function()
  local d, dir
  before_each(function()
    dir = vim.fn.tempname()
  end)
  after_each(function()
    if d then
      d:close()
      d = nil
    end
    vim.fn.delete(dir, 'rf')
  end)

  it('renames a file connection: drawer and json both update', function()
    connections.write_file(dir .. '/connections.json', { { name = 'old', url = 'sqlite:' .. dir .. '/old.db' } })
    d = make_drawer({ save_location = dir, file_entries = { { name = 'old', url = 'sqlite:' .. dir .. '/old.db' } } })
    d.input = (function()
      local q = { 'sqlite:' .. dir .. '/new.db', 'new' }
      local i = 0
      return function(_, cb)
        i = i + 1
        cb(q[i])
      end
    end)()

    d:rename_connection(entry_named(d, 'old'))
    local file = stored(d.instance.connections_path)
    assert.equals('new', file[1].name)
    assert.is_not_nil(entry_named(d, 'new'))
    assert.is_nil(entry_named(d, 'old'))
  end)

  it('refuses to rename onto an existing connection name and writes nothing', function()
    local seed = {
      { name = 'Geekom', url = 'sqlite:' .. dir .. '/a.db' },
      { name = 'Geekom2', url = 'sqlite:' .. dir .. '/b.db' },
    }
    connections.write_file(dir .. '/connections.json', seed)
    d = make_drawer({ save_location = dir, file_entries = seed })
    d.input = (function()
      local q = { 'sqlite:' .. dir .. '/b.db', 'Geekom' }
      local i = 0
      return function(_, cb)
        i = i + 1
        cb(q[i])
      end
    end)()

    d:rename_connection(entry_named(d, 'Geekom2'))
    local file = stored(d.instance.connections_path)
    assert.equals(2, #file) -- nothing merged or dropped
    assert.is_not_nil(entry_named(d, 'Geekom'))
    assert.is_not_nil(entry_named(d, 'Geekom2'))
    assert.is_truthy(notifications.get_last_msg():find('already exists'))
  end)

  it('refuses to rename a non-file connection', function()
    d = make_drawer({ save_location = dir, g_dbs = { dev = 'postgres://h/dev' } })
    d:rename_connection(entry_named(d, 'dev'))
    assert.is_truthy(notifications.get_last_msg():find('via variables'))
  end)
end)

describe('connection management: group', function()
  local d, dir
  before_each(function()
    dir = vim.fn.tempname()
  end)
  after_each(function()
    if d then
      d:close()
      d = nil
    end
    vim.fn.delete(dir, 'rf')
  end)

  local function lines(drawer)
    return vim.api.nvim_buf_get_lines(drawer.bufnr, 0, -1, false)
  end

  it('assigns a file connection to a group: drawer header + json both update', function()
    local seed = { { name = 'qa', url = 'sqlite:' .. dir .. '/qa.db' } }
    connections.write_file(dir .. '/connections.json', seed)
    d = make_drawer({ save_location = dir, file_entries = seed, inputs = { 'Local' } })
    d:open()
    d:set_group(entry_named(d, 'qa'))

    assert.equals('Local', stored(d.instance.connections_path)[1].group)
    assert.equals('Local', entry_named(d, 'qa').group)
    -- a group header now precedes the connection in the tree
    local l = lines(d)
    assert.is_truthy(l[1]:find('Local'))
    assert.is_truthy(vim.tbl_contains(l, '  ▸ qa'))
  end)

  it('refuses to group a non-file connection', function()
    d = make_drawer({ save_location = dir, g_dbs = { dev = 'postgres://h/dev' } })
    d:set_group(entry_named(d, 'dev'))
    assert.is_truthy(notifications.get_last_msg():find('via variables'))
  end)

  it('shows the group with its icon under details (H)', function()
    local seed = { { name = 'qa', url = 'sqlite:' .. dir .. '/qa.db', group = 'Local' } }
    connections.write_file(dir .. '/connections.json', seed)
    d = make_drawer({ save_location = dir, file_entries = seed })
    d:open()
    d.groups['Local'] = { expanded = true }
    d:toggle_details()
    local qa_line
    for _, l in ipairs(lines(d)) do
      if l:find('qa %(') then
        qa_line = l
      end
    end
    assert.is_truthy(qa_line)
    assert.is_truthy(qa_line:find('sqlite'))
    assert.is_truthy(qa_line:find('Local'))
    assert.is_truthy(qa_line:find(d.icons.group, 1, true))
    -- the group header itself is labelled as a group under details
    assert.is_truthy(vim.tbl_contains(lines(d), '▾ Local (Group)'))
  end)
end)

describe('connection management: delete', function()
  local d, dir
  before_each(function()
    dir = vim.fn.tempname()
  end)
  after_each(function()
    if d then
      d:close()
      d = nil
    end
    vim.fn.delete(dir, 'rf')
  end)

  it('deletes a confirmed file connection from drawer and json', function()
    connections.write_file(dir .. '/connections.json', { { name = 'qa', url = 'sqlite:' .. dir .. '/qa.db' } })
    d = make_drawer({
      save_location = dir,
      file_entries = { { name = 'qa', url = 'sqlite:' .. dir .. '/qa.db' } },
      confirm = true,
    })
    d:delete_connection(entry_named(d, 'qa'))
    assert.equals(0, #stored(d.instance.connections_path))
    assert.is_nil(entry_named(d, 'qa'))
  end)

  it('does nothing when the confirmation is declined', function()
    connections.write_file(dir .. '/connections.json', { { name = 'qa', url = 'sqlite:' .. dir .. '/qa.db' } })
    d = make_drawer({
      save_location = dir,
      file_entries = { { name = 'qa', url = 'sqlite:' .. dir .. '/qa.db' } },
      confirm = false,
    })
    d:delete_connection(entry_named(d, 'qa'))
    assert.equals(1, #stored(d.instance.connections_path))
  end)

  it('refuses to delete a non-file connection via delete_line', function()
    d = make_drawer({ save_location = dir, g_dbs = { dev = 'postgres://h/dev' } })
    d:open()
    vim.api.nvim_win_set_cursor(d.winid, { 1, 0 })
    d:delete_line()
    assert.is_truthy(notifications.get_last_msg():find('Cannot delete'))
  end)
end)

describe('connection management: redraw', function()
  local d, dir
  before_each(function()
    dir = vim.fn.tempname()
  end)
  after_each(function()
    if d then
      d:close()
      d = nil
    end
    vim.fn.delete(dir, 'rf')
  end)

  it('refreshes without error', function()
    d = make_drawer({ save_location = dir, g_dbs = { dev = 'postgres://h/dev' } })
    d:open()
    vim.api.nvim_win_set_cursor(d.winid, { 1, 0 })
    assert.has_no.errors(function()
      d:redraw()
    end)
    assert.is_not_nil(entry_named(d, 'dev'))
  end)

  it('preserves an expanded connection across a redraw', function()
    d = make_drawer({ save_location = dir, g_dbs = { dev = 'postgres://h/dev' } })
    d:open()
    entry_named(d, 'dev').expanded = true
    vim.api.nvim_win_set_cursor(d.winid, { 1, 0 })
    d:redraw()
    assert.is_true(entry_named(d, 'dev').expanded)
  end)
end)

describe('connection management: preserves state across an edit', function()
  local d, dir
  before_each(function()
    dir = vim.fn.tempname()
  end)
  after_each(function()
    if d then
      d:close()
      d = nil
    end
    vim.fn.delete(dir, 'rf')
  end)

  it('keeps an unrelated connection expanded after adding another', function()
    d = make_drawer({ save_location = dir, g_dbs = { dev = 'postgres://h/dev' }, inputs = { 'sqlite:' .. dir .. '/qa.db', 'qa' } })
    d:open()
    entry_named(d, 'dev').expanded = true
    d:add_connection()
    assert.is_not_nil(entry_named(d, 'qa')) -- the add landed
    assert.is_true(entry_named(d, 'dev').expanded) -- and dev stayed open
  end)
end)
