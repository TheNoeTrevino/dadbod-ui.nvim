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
    assert.same({ 'new_query', 'buffers', 'saved_queries', 'schemas' }, c.drawer_sections)
  end)

  it('lets setup opts override defaults', function()
    local c = config.resolve({ winwidth = 80, win_position = 'right' })
    assert.equals(80, c.winwidth)
    assert.equals('right', c.win_position)
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
end)
