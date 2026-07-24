-- Specs for table "Script As" (issue #90): the drawer's table -> "Script As"
-- subtree and its dispatch into the generic script_as orchestrator. Adapter
-- action sets (queries, parsers, builders) get their own describes as each
-- engine lands. All pure or mock-driven -- no live database.

local schemas = require('dadbod-ui.schemas')
local drawer_mod = require('dadbod-ui.drawer')
local ids = require('dadbod-ui.drawer.ids')
local state = require('dadbod-ui.state')
local config = require('dadbod-ui.config')
local script_as = require('dadbod-ui.script_as')

-- A drawer over an instance seeded with injected connections (offline connector).
-- `make_drawer`/`entry_named`/`lines` follow the per-spec convention (see
-- routine_scripts_spec.lua); there is no shared test-helper module for them.
local function make_drawer(g_dbs, overrides)
  local cfg = config.resolve(
    vim.tbl_extend(
      'force',
      { save_location = '/tmp/dbui_tbl_scripts', drawer = { show_help = false } },
      overrides or {}
    )
  )
  local instance = state.new(cfg):populate({ env = {}, g_dbs = g_dbs, file_entries = {} })
  local d = drawer_mod.new(instance)
  d.connector = function(url)
    return url
  end
  return d
end

local function entry_named(d, name)
  for _, record in ipairs(d.instance.dbs_list) do
    if record.name == name then
      return d.instance.dbs[record.key_name]
    end
  end
end

local function lines(d)
  return vim.api.nvim_buf_get_lines(d.bufnr, 0, -1, false)
end

--- Whether any rendered drawer line contains `text` (plain substring).
local function has_line(d, text)
  return vim.iter(lines(d)):any(function(l)
    return l:find(text, 1, true)
  end)
end

--- The first rendered node whose label is exactly `label`.
local function node_labeled(d, label)
  return vim.iter(d.content):find(function(node)
    return node.label == label
  end)
end

describe('table_scripts: drawer rendering', function()
  local d
  after_each(function()
    if d then
      d:close()
      d = nil
    end
  end)

  --- Seed one `users` table under `public` and expand down into it, with an
  --- injected capability (adapters grow their real `table_scripts` in later
  --- commits; the drawer only cares that the entry carries one).
  local function render_table(capability)
    d = make_drawer({ dev = 'postgres://h/dev' })
    d:open()
    local entry = entry_named(d, 'dev')
    entry.table_scripts = capability
    entry.schemas.list = { 'public' }
    entry.schemas.items = { public = { 'users' } }
    d:set_expanded(ids.db(entry.key_name), true)
    d:set_expanded(ids.section(entry.key_name, 'schemas'), true)
    d:set_expanded(ids.schema(entry.key_name, 'public'), true)
    d:set_expanded(ids.table(entry.key_name, 'public', 'users'), true)
    return entry
  end

  it('a table with the capability expands to Script As ahead of its helpers', function()
    local entry = render_table({ actions = { { label = 'FAKE To' } } })
    d:set_expanded(ids.table_script_as(entry.key_name, 'public', 'users'), true)
    d:render()
    assert.is_truthy(has_line(d, 'Script As'))
    assert.is_truthy(has_line(d, 'FAKE To'))
    -- pinned first: the submenu leads the (user-orderable) helper leaves
    local script_node = node_labeled(d, 'Script As')
    local list_node = node_labeled(d, 'List')
    assert.is_truthy(script_node.index < list_node.index)
  end)

  it('without the capability a table lists only its helpers', function()
    render_table(nil)
    d:render()
    assert.is_truthy(has_line(d, 'List'))
    assert.is_falsy(has_line(d, 'Script As'))
  end)

  it("an action leaf's on_activate dispatches to script_as.run with kind 'table'", function()
    local entry = render_table({ actions = { { label = 'FAKE To' } } })
    d:set_expanded(ids.table_script_as(entry.key_name, 'public', 'users'), true)
    d:render()
    local real_run = script_as.run
    local got
    script_as.run = function(opts)
      got = opts
    end
    local ok, err = pcall(function()
      node_labeled(d, 'FAKE To').on_activate()
    end)
    script_as.run = real_run
    assert.is_truthy(ok, err)
    assert.equals('table', got.kind)
    assert.equals('users', got.name)
    assert.equals('public', got.schema)
    assert.equals(entry, got.entry)
    assert.equals('FAKE To', got.action.label)
  end)
end)
