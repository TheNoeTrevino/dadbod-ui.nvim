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
    d:connections():add_connection()

    local file = stored(d.instance.connections_path)
    assert.equals(1, #file)
    assert.equals('qa', file[1].name)
    assert.is_not_nil(entry_named(d, 'qa'))
    assert.is_truthy(vim.tbl_contains(vim.api.nvim_buf_get_lines(d.bufnr, 0, -1, false), '▸ qa'))
  end)

  it('rejects a duplicate name and writes nothing', function()
    connections.write_file(dir .. '/connections.json', { { name = 'qa', url = 'sqlite:' .. dir .. '/qa.db' } })
    d = make_drawer({ save_location = dir, inputs = { 'sqlite:' .. dir .. '/other.db', 'qa' } })
    d:connections():add_connection()

    local file = stored(d.instance.connections_path)
    assert.equals(1, #file)
    assert.equals('sqlite:' .. dir .. '/qa.db', file[1].url) -- untouched
    assert.is_truthy(notifications.get_last_msg():find('already exists'))
  end)

  it('rejects a blank name and writes nothing', function()
    d = make_drawer({ save_location = dir, inputs = { 'sqlite:' .. dir .. '/qa.db', '   ' } })
    d:connections():add_connection()
    assert.equals(0, #stored(d.instance.connections_path))
    assert.is_truthy(notifications.get_last_msg():find('valid name'))
  end)

  it('refuses with no save location set', function()
    d = make_drawer({ save_location = '', inputs = { 'sqlite:/x.db', 'x' } })
    d:connections():add_connection()
    assert.is_truthy(notifications.get_last_msg():find('save location'))
  end)

  it('refuses to overwrite a corrupt connections.json on add', function()
    vim.fn.mkdir(dir, 'p')
    local path = dir .. '/connections.json'
    vim.fn.writefile({ '{ corrupt not an array' }, path)
    d = make_drawer({ save_location = dir, inputs = { 'sqlite:' .. dir .. '/qa.db', 'qa' } })
    d:connections():add_connection()

    -- the original corrupt bytes are still on disk, untouched
    assert.equals('{ corrupt not an array', vim.fn.readfile(path)[1])
    assert.is_nil(entry_named(d, 'qa'))
    assert.is_truthy(notifications.get_last_msg():find('refusing to overwrite'))
  end)

  it('persists the raw typed url so env references are not expanded to plaintext', function()
    -- $DBUI_TEST_PASS resolves to a secret; only the raw reference must hit disk,
    -- so the password stays out of connections.json and env rotation keeps working.
    vim.fn.setenv('DBUI_TEST_PASS', 'secret123')
    local raw = 'postgres://user:$DBUI_TEST_PASS@localhost/shop'
    d = make_drawer({ save_location = dir, inputs = { raw, 'shop' } })
    d:connections():add_connection()

    local file = stored(d.instance.connections_path)
    assert.equals(1, #file)
    assert.equals(raw, file[1].url) -- stored verbatim, unresolved
    assert.is_nil(file[1].url:find('secret123', 1, true)) -- secret never written
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

    d:connections():rename_connection(entry_named(d, 'old'))
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

    d:connections():rename_connection(entry_named(d, 'Geekom2'))
    local file = stored(d.instance.connections_path)
    assert.equals(2, #file) -- nothing merged or dropped
    assert.is_not_nil(entry_named(d, 'Geekom'))
    assert.is_not_nil(entry_named(d, 'Geekom2'))
    assert.is_truthy(notifications.get_last_msg():find('already exists'))
  end)

  it('refuses to rename a non-file connection', function()
    d = make_drawer({ save_location = dir, g_dbs = { dev = 'postgres://h/dev' } })
    d:connections():rename_connection(entry_named(d, 'dev'))
    assert.is_truthy(notifications.get_last_msg():find('via variables'))
  end)
end)

describe('connection management: duplicate', function()
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

  it('duplicates a connection into the drawer and json with a new name + url', function()
    local seed = { { name = 'main', url = 'sqlite:' .. dir .. '/main.db' } }
    connections.write_file(dir .. '/connections.json', seed)
    -- prompts: name, url, group (ungrouped here)
    d = make_drawer({
      save_location = dir,
      file_entries = seed,
      inputs = { 'analytics', 'sqlite:' .. dir .. '/analytics.db', '' },
    })

    d:connections():duplicate_connection(entry_named(d, 'main'))
    local file = stored(d.instance.connections_path)
    assert.equals(2, #file)
    assert.is_not_nil(entry_named(d, 'main')) -- source kept
    assert.is_not_nil(entry_named(d, 'analytics')) -- copy added
    assert.equals('sqlite:' .. dir .. '/analytics.db', entry_named(d, 'analytics').url)
  end)

  it('prefills the group prompt with the source group', function()
    local seed = { { name = 'pg', url = 'sqlite:' .. dir .. '/a.db', group = 'Servers' } }
    connections.write_file(dir .. '/connections.json', seed)
    d = make_drawer({ save_location = dir, file_entries = seed })
    -- accept the prefilled group (3rd prompt) by returning its default
    d.input = (function()
      local q = { 'pg2', 'sqlite:' .. dir .. '/b.db' }
      local i = 0
      return function(opts, cb)
        i = i + 1
        cb(i <= 2 and q[i] or opts.default)
      end
    end)()

    d:connections():duplicate_connection(entry_named(d, 'pg'))
    local copy = vim.tbl_filter(function(c)
      return c.name == 'pg2'
    end, stored(d.instance.connections_path))[1]
    assert.equals('Servers', copy.group)
  end)

  it('clones a same-name connection into a different group', function()
    local seed = { { name = 'postgres', url = 'postgres://geekom/db', group = 'geekom' } }
    connections.write_file(dir .. '/connections.json', seed)
    -- keep the name, change only the group: geekom/postgres -> pi/postgres
    d = make_drawer({ save_location = dir, file_entries = seed, inputs = { 'postgres', 'postgres://pi/db', 'pi' } })

    d:connections():duplicate_connection(entry_named(d, 'postgres'))
    local file = stored(d.instance.connections_path)
    assert.equals(2, #file)
    local groups = vim.tbl_map(function(c)
      return c.group
    end, file)
    assert.is_true(vim.tbl_contains(groups, 'geekom'))
    assert.is_true(vim.tbl_contains(groups, 'pi'))
  end)

  it('refuses a same name in the same group and writes nothing', function()
    local seed = { { name = 'a', url = 'sqlite:' .. dir .. '/a.db' } }
    connections.write_file(dir .. '/connections.json', seed)
    d = make_drawer({ save_location = dir, file_entries = seed, inputs = { 'a', 'sqlite:' .. dir .. '/b.db', '' } })

    d:connections():duplicate_connection(entry_named(d, 'a'))
    assert.equals(1, #stored(d.instance.connections_path))
    assert.is_truthy(notifications.get_last_msg():find('already exists'))
  end)

  it('can duplicate a variable-source connection into an editable file one', function()
    d = make_drawer({
      save_location = dir,
      g_dbs = { dev = 'postgres://h/dev' },
      inputs = { 'dev_file', 'postgres://h/dev', '' },
    })
    d:connections():duplicate_connection(entry_named(d, 'dev'))
    local file = stored(d.instance.connections_path)
    assert.equals(1, #file)
    assert.equals('dev_file', file[1].name)
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
    d:connections():set_group(entry_named(d, 'qa'))

    assert.equals('Local', stored(d.instance.connections_path)[1].group)
    assert.equals('Local', entry_named(d, 'qa').group)
    -- a group header now precedes the connection in the tree
    local l = lines(d)
    assert.is_truthy(l[1]:find('Local'))
    assert.is_truthy(vim.tbl_contains(l, '  ▸ qa'))
  end)

  it('renders one header per group even when members are not contiguous', function()
    -- group members interleaved with an ungrouped connection of the same name
    local seed = {
      { name = 'Geekom', url = 'sqlite:' .. dir .. '/a.db', group = 'Test' },
      { name = 'Geekom', url = 'sqlite:' .. dir .. '/b.db' },
      { name = 'post', url = 'sqlite:' .. dir .. '/c.db', group = 'Test' },
    }
    connections.write_file(dir .. '/connections.json', seed)
    d = make_drawer({ save_location = dir, file_entries = seed })
    d.groups['Test'] = { expanded = true }
    d:open()
    local l = lines(d)
    -- exactly one "Test" header, with both grouped members under it
    local headers = 0
    for _, line in ipairs(l) do
      if line == '▾ Test' or line == '▸ Test' then
        headers = headers + 1
      end
    end
    assert.equals(1, headers)
    assert.is_truthy(vim.tbl_contains(l, '  ▸ Geekom'))
    assert.is_truthy(vim.tbl_contains(l, '  ▸ post'))
    -- the ungrouped Geekom still renders at top level
    assert.is_truthy(vim.tbl_contains(l, '▸ Geekom'))
  end)

  it('refuses to group a non-file connection', function()
    d = make_drawer({ save_location = dir, g_dbs = { dev = 'postgres://h/dev' } })
    d:connections():set_group(entry_named(d, 'dev'))
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
    d:connections():delete_connection(entry_named(d, 'qa'))
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
    d:connections():delete_connection(entry_named(d, 'qa'))
    assert.equals(1, #stored(d.instance.connections_path))
  end)

  it('refuses to delete a non-file connection via delete_line', function()
    d = make_drawer({ save_location = dir, g_dbs = { dev = 'postgres://h/dev' } })
    d:open()
    vim.api.nvim_win_set_cursor(d.winid, { 1, 0 })
    d:delete_line()
    assert.is_truthy(notifications.get_last_msg():find('Cannot delete'))
  end)

  it('refuses to delete a non-file connection at the controller (guards the store)', function()
    -- Even called directly, the controller must refuse a variable-source entry so
    -- it can't rewrite connections.json (or drop a file entry sharing name+url).
    d = make_drawer({ save_location = dir, g_dbs = { dev = 'postgres://h/dev' }, confirm = true })
    d:connections():delete_connection(entry_named(d, 'dev'))
    assert.is_truthy(notifications.get_last_msg():find('via variables'))
  end)

  it('deletes only the targeted clone when a same name+url lives in two groups', function()
    -- geekom/postgres and pi/postgres share name AND url; deleting the pi clone
    -- must leave geekom's intact (the controller threads entry.group through).
    local seed = {
      { name = 'postgres', url = 'sqlite:' .. dir .. '/db', group = 'geekom' },
      { name = 'postgres', url = 'sqlite:' .. dir .. '/db', group = 'pi' },
    }
    connections.write_file(dir .. '/connections.json', seed)
    d = make_drawer({ save_location = dir, file_entries = seed, confirm = true })
    d:connections():delete_connection(d.instance.dbs['pi_postgres_file'])

    local file = stored(d.instance.connections_path)
    assert.equals(1, #file)
    assert.equals('geekom', file[1].group)
  end)
end)

describe('connection management: reorder', function()
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

  local function stored_names(path)
    return vim.tbl_map(function(c)
      return c.name
    end, stored(path))
  end

  local function db_line(drawer, name)
    for idx, node in ipairs(drawer.content) do
      if node.type == 'db' and node.label:find(name, 1, true) then
        return idx
      end
    end
  end

  it('moves a connection down: reorders both json and the drawer', function()
    local seed = {
      { name = 'a', url = 'sqlite:' .. dir .. '/a.db' },
      { name = 'b', url = 'sqlite:' .. dir .. '/b.db' },
    }
    connections.write_file(dir .. '/connections.json', seed)
    d = make_drawer({ save_location = dir, file_entries = seed })
    d:open()
    vim.api.nvim_win_set_cursor(d.winid, { db_line(d, 'a'), 0 })
    d:move_line('down')

    assert.same({ 'b', 'a' }, stored_names(d.instance.connections_path))
    -- the cursor followed the moved connection
    assert.equals(d:current_line(), db_line(d, 'a'))
  end)

  it('clamps: moving the first connection up does nothing', function()
    local seed = {
      { name = 'a', url = 'sqlite:' .. dir .. '/a.db' },
      { name = 'b', url = 'sqlite:' .. dir .. '/b.db' },
    }
    connections.write_file(dir .. '/connections.json', seed)
    d = make_drawer({ save_location = dir, file_entries = seed })
    d:open()
    vim.api.nvim_win_set_cursor(d.winid, { db_line(d, 'a'), 0 })
    d:move_line('up')
    assert.same({ 'a', 'b' }, stored_names(d.instance.connections_path))
  end)

  it('refuses to move a discovered (variable) connection', function()
    d = make_drawer({ save_location = dir, g_dbs = { dev = 'postgres://h/dev' } })
    d:connections():move_connection(entry_named(d, 'dev'), 'down')
    assert.is_truthy(notifications.get_last_msg():find('via variables'))
  end)

  it('moving a connection down into a group joins it, cursor follows', function()
    local seed = {
      { name = 'a', url = 'sqlite:' .. dir .. '/a.db' },
      { name = 'b', url = 'sqlite:' .. dir .. '/b.db', group = 'G' },
    }
    connections.write_file(dir .. '/connections.json', seed)
    d = make_drawer({ save_location = dir, file_entries = seed })
    d.groups['G'] = { expanded = true }
    d:open()
    -- a is ungrouped, directly above group G; C-Down crosses the boundary into G
    vim.api.nvim_win_set_cursor(d.winid, { db_line(d, 'a'), 0 })
    d:move_line('down')

    local a = vim.tbl_filter(function(c)
      return c.name == 'a'
    end, stored(d.instance.connections_path))[1]
    assert.equals('G', a.group) -- adopted the group it crossed into
    -- the cursor followed the connection to its new (grouped) line
    assert.equals(d:current_line(), db_line(d, 'a'))
  end)

  it('refuses to move a connection into a group holding a same-name connection', function()
    local seed = {
      { name = 'dev', url = 'sqlite:' .. dir .. '/a.db', group = 'G' },
      { name = 'dev', url = 'sqlite:' .. dir .. '/b.db' },
    }
    connections.write_file(dir .. '/connections.json', seed)
    d = make_drawer({ save_location = dir, file_entries = seed })
    d.groups['G'] = { expanded = true }
    d:open()
    -- the ungrouped dev sits below group G's dev; crossing up would duplicate it
    local ungrouped_dev = d.instance.dbs['dev_file']
    d:connections():move_connection(ungrouped_dev, 'up')
    assert.equals(2, #stored(d.instance.connections_path)) -- nothing merged
    assert.is_truthy(notifications.get_last_msg():find('already exists'))
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
    d = make_drawer({
      save_location = dir,
      g_dbs = { dev = 'postgres://h/dev' },
      inputs = { 'sqlite:' .. dir .. '/qa.db', 'qa' },
    })
    d:open()
    entry_named(d, 'dev').expanded = true
    d:connections():add_connection()
    assert.is_not_nil(entry_named(d, 'qa')) -- the add landed
    assert.is_true(entry_named(d, 'dev').expanded) -- and dev stayed open
  end)
end)
