local config = require('dadbod-ui.config')

describe('config', function()
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
