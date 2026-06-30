local mappings = require('dadbod-ui.mappings')
local config = require('dadbod-ui.config')

describe('mappings.binds', function()
  it('expands a single key in the default normal mode', function()
    assert.same({ { mode = 'n', lhs = 'q' } }, mappings.binds({ key = 'q', desc = 'x' }))
  end)

  it('expands a list of aliases', function()
    assert.same(
      { { mode = 'n', lhs = 'o' }, { mode = 'n', lhs = '<CR>' } },
      mappings.binds({ key = { 'o', '<CR>' }, desc = 'x' })
    )
  end)

  it('expands across multiple modes', function()
    assert.same(
      { { mode = 'n', lhs = '<Leader>S' }, { mode = 'v', lhs = '<Leader>S' } },
      mappings.binds({ key = '<Leader>S', desc = 'x', mode = { 'n', 'v' } })
    )
  end)

  it('uses an explicit binds list verbatim (per-mode keys)', function()
    local binds = { { mode = 'n', lhs = 'vic' }, { mode = 'o', lhs = 'ic' } }
    assert.same(binds, mappings.binds({ key = 'vic', desc = 'x', binds = binds }))
  end)

  it('returns no binds for a disabled (none) or missing entry', function()
    assert.same({}, mappings.binds({ key = 'none', desc = 'x' }))
    assert.same({}, mappings.binds(nil))
  end)
end)

describe('mappings.apply', function()
  it('binds configured keys to handlers and skips disabled / handlerless ones', function()
    local buf = vim.api.nvim_create_buf(false, true)
    local hit = {}
    local group = {
      go = { key = 'g', desc = 'x' },
      off = { key = 'none', desc = 'x' },
      orphan = { key = 'p', desc = 'x' }, -- no handler -> not bound
    }
    mappings.apply(group, { 'go', 'off', 'orphan' }, {
      go = function()
        hit.go = true
      end,
      off = function()
        hit.off = true
      end,
    }, { buffer = buf })

    local lhs = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      lhs[m.lhs] = true
    end
    assert.is_truthy(lhs['g'])
    assert.is_nil(lhs['p']) -- handlerless, unbound
    assert.is_nil(lhs['<Nop>'])
    -- 'off' is disabled, so no key was registered for it at all.
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe('mappings.display_key', function()
  it('joins aliases with a slash', function()
    assert.equals('o / <CR>', mappings.display_key({ key = { 'o', '<CR>' }, desc = 'x' }))
    assert.equals('q', mappings.display_key({ key = 'q', desc = 'x' }))
  end)
end)

describe('mappings.help_lines', function()
  it('renders one section per context, key-aligned, omitting disabled actions', function()
    local cfg = config.resolve({
      mappings = { sidebar = { duplicate = { key = 'none' } } },
    })
    local lines = mappings.help_lines(cfg)

    -- Section headers appear in the fixed order.
    local function index_of(title)
      for i, l in ipairs(lines) do
        if l == title then
          return i
        end
      end
    end
    assert.is_truthy(index_of('Sidebar'))
    assert.is_truthy(index_of('Query Buffer'))
    assert.is_truthy(index_of('DB Results'))
    assert.is_true(index_of('Sidebar') < index_of('Query Buffer'))
    assert.is_true(index_of('Query Buffer') < index_of('DB Results'))

    local blob = table.concat(lines, '\n')
    assert.is_truthy(blob:find('Open/Toggle selected item', 1, true))
    assert.is_truthy(blob:find('Execute query', 1, true))
    -- The disabled action is gone.
    assert.is_falsy(blob:find('Duplicate connection', 1, true))
  end)

  it('drops a whole section when all its actions are disabled', function()
    local none = function(group)
      local out = {}
      for id in pairs(group) do
        out[id] = { key = 'none' }
      end
      return out
    end
    local cfg = config.resolve({ mappings = { results = none(config.defaults.mappings.results) } })
    local lines = mappings.help_lines(cfg)
    assert.is_falsy(vim.tbl_contains(lines, 'DB Results'))
    assert.is_truthy(vim.tbl_contains(lines, 'Sidebar'))
  end)
end)
