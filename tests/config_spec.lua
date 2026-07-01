local config = require('dadbod-ui.config')

describe('config', function()
  local saved = {}
  local function set_global(name, value)
    saved[name] = vim.g[name]
    vim.g[name] = value
  end

  after_each(function()
    for name, value in pairs(saved) do
      vim.g[name] = value
    end
    saved = {}
  end)

  it('exposes defaults', function()
    local c = config.resolve()
    assert.equals(40, c.winwidth)
    assert.equals('left', c.win_position)
    assert.equals(true, c.show_help)
    assert.equals('horizontal', c.result_layout)
    assert.same({ 'new_query', 'buffers', 'saved_queries', 'schemas' }, c.drawer_sections)
  end)

  it('lets setup opts override defaults', function()
    local c = config.resolve({ winwidth = 80, win_position = 'right' })
    assert.equals(80, c.winwidth)
    assert.equals('right', c.win_position)
  end)

  it('lets setup opts switch the result layout to vertical', function()
    assert.equals('vertical', config.resolve({ result_layout = 'vertical' }).result_layout)
  end)

  it('reads legacy g:db_ui_* globals', function()
    set_global('db_ui_winwidth', 100)
    assert.equals(100, config.resolve().winwidth)
  end)

  it('coerces legacy 0/1 booleans to real booleans', function()
    set_global('db_ui_show_help', 0)
    assert.equals(false, config.resolve().show_help)
    set_global('db_ui_use_nerd_fonts', 1)
    assert.equals(true, config.resolve().use_nerd_fonts)
  end)

  it('gives setup opts precedence over legacy globals', function()
    set_global('db_ui_winwidth', 100)
    assert.equals(25, config.resolve({ winwidth = 25 }).winwidth)
  end)

  it('treats the 0 funcref sentinel as unset', function()
    set_global('Db_ui_buffer_name_generator', 0)
    assert.is_nil(config.resolve().buffer_name_generator)
  end)

  it('takes a function from setup opts by identity', function()
    local fn = function()
      return 'x'
    end
    assert.equals(fn, config.resolve({ buffer_name_generator = fn }).buffer_name_generator)
  end)

  it('exposes the export defaults', function()
    local c = config.resolve()
    assert.equals(true, c.export.prefer_native)
    assert.equals(false, c.export.coerce_numbers)
    assert.equals(',', c.export.csv.delimiter)
    assert.equals(true, c.export.json.wrap_table_name)
  end)

  it('deep-merges export overrides, leaving sibling keys intact', function()
    local c = config.resolve({ export = { prefer_native = false, csv = { delimiter = ';' } } })
    assert.equals(false, c.export.prefer_native)
    assert.equals(';', c.export.csv.delimiter)
    assert.equals(true, c.export.csv.header) -- untouched sibling preserved
  end)

  it('registers the results.export mapping and its order entry', function()
    local c = config.resolve()
    assert.equals('<Leader>X', c.mappings.results.export.key)
    assert.is_true(vim.tbl_contains(config.mapping_order.results, 'export'))
  end)
end)
