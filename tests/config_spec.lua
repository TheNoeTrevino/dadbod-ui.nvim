local config = require('dadbod-ui.config')

describe('config', function()
  -- Sentinel so a global that was ORIGINALLY unset is restored to nil rather than
  -- left set. Storing a bare nil in `saved` wouldn't create the key, so after_each
  -- would skip it and the global would leak across specs (harmless under plenary's
  -- per-file nvim, but the mini.test runner shares one process).
  local UNSET = {}
  local saved = {}
  local function set_global(name, value)
    if saved[name] == nil then
      local current = vim.g[name]
      saved[name] = current == nil and UNSET or current
    end
    vim.g[name] = value
  end

  after_each(function()
    for name, value in pairs(saved) do
      vim.g[name] = value ~= UNSET and value or nil
    end
    saved = {}
  end)

  it('exposes defaults', function()
    local c = config.resolve()
    assert.equals(40, c.winwidth)
    assert.equals('left', c.win_position)
    assert.equals(true, c.show_help)
    assert.equals('horizontal', c.result_layout)
    assert.same({ 'new_query', 'buffers', 'saved_queries', 'schemas', 'procedures' }, c.drawer_sections)
  end)

  it('lets setup opts override defaults', function()
    local c = config.resolve({ winwidth = 80, win_position = 'right' })
    assert.equals(80, c.winwidth)
    assert.equals('right', c.win_position)
  end)

  it('lets setup opts switch the result layout to vertical', function()
    assert.equals('vertical', config.resolve({ result_layout = 'vertical' }).result_layout)
  end)

  it('reads g:db_ui_* globals', function()
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

  it('freezes the resolved config against stray new fields', function()
    local c = config.resolve()
    assert.has_error(function()
      ---@diagnostic disable-next-line: inject-field
      c.wnwidth = 80 -- a typo'd option must not silently land on the shared config
    end)
  end)

  it('freezes nested config tables too', function()
    local c = config.resolve()
    assert.has_error(function()
      ---@diagnostic disable-next-line: inject-field
      c.export.new_format = {}
    end)
  end)

  it('leaves reads, iteration and deepcopy working through the freeze', function()
    local c = config.resolve()
    assert.equals(200, c.page_size) -- index
    assert.same({ 'new_query', 'buffers', 'saved_queries', 'schemas', 'procedures' }, c.drawer_sections) -- pairs
    -- deepcopy of a (non-empty) frozen subtable yields a mutable copy, not a crash
    local copy = vim.deepcopy(c.export)
    assert.equals(',', copy.csv.delimiter)
    copy.csv.delimiter = ';' -- the copy must be writable
    assert.equals(';', copy.csv.delimiter)
  end)
end)
