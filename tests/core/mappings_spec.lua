local mappings = require('dadbod-ui.mappings')
local config = require('dadbod-ui.config')

describe('mappings.normalize', function()
  it('binds a bare string action in normal mode', function()
    assert.same({ action = 'toggle', modes = { 'n' } }, mappings.normalize('toggle'))
  end)

  it('reads the action and mode(s) from a table spec', function()
    assert.same({ action = 'execute', modes = { 'n', 'v' } }, mappings.normalize({ 'execute', mode = { 'n', 'v' } }))
    assert.same({ action = 'cell_value', modes = { 'o' } }, mappings.normalize({ 'cell_value', mode = 'o' }))
  end)

  it('returns nil for a disabled or missing spec', function()
    assert.is_nil(mappings.normalize(false))
    assert.is_nil(mappings.normalize(nil))
  end)
end)

describe('mappings.apply', function()
  it('binds keys to built-in handlers and user actions, skipping disabled / unknown', function()
    local buf = vim.api.nvim_create_buf(false, true)
    local hit = {}
    local keys = {
      ['g'] = 'go', -- built-in handler
      ['x'] = false, -- disabled
      ['p'] = 'orphan', -- no handler + not a user action -> unbound
      ['u'] = 'yank_url', -- user action
    }
    local ctx_seen
    mappings.apply(keys, {
      go = function()
        hit.go = true
      end,
    }, {
      yank_url = function(ctx)
        ctx_seen = ctx
      end,
    }, function(mode)
      return { mode = mode, bufnr = buf }
    end, { buffer = buf })

    local lhs = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      lhs[m.lhs] = true
    end
    assert.is_truthy(lhs['g'])
    assert.is_truthy(lhs['u'])
    assert.is_nil(lhs['p']) -- unknown action, unbound
    assert.is_nil(lhs['x']) -- disabled
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it('is a no-op when the context keys are false', function()
    local buf = vim.api.nvim_create_buf(false, true)
    mappings.apply(false, { go = function() end }, {}, function() end, { buffer = buf })
    assert.same({}, vim.api.nvim_buf_get_keymap(buf, 'n'))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it('passes the per-invocation context to a user action', function()
    local buf = vim.api.nvim_create_buf(false, true)
    local seen
    mappings.apply({ ['gu'] = 'grab' }, {}, {
      grab = {
        desc = 'x',
        fn = function(ctx)
          seen = ctx
        end,
      },
    }, function(mode)
      return { mode = mode, bufnr = buf, connection = { url = 'x' } }
    end, { buffer = buf })
    -- invoke the bound callback directly
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      if m.lhs == 'gu' and m.callback then
        m.callback()
      end
    end
    assert.equals('n', seen.mode)
    assert.equals('x', seen.connection.url)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe('mappings.keys_for_action', function()
  it('joins the lhs values bound to an action (sorted)', function()
    local keys = { ['o'] = 'toggle', ['<CR>'] = 'toggle', [']'] = 'next_page' }
    assert.equals('<CR> / o', mappings.keys_for_action(keys, 'toggle'))
    assert.equals(']', mappings.keys_for_action(keys, 'next_page'))
  end)

  it('returns an empty string for an unbound action', function()
    assert.equals('', mappings.keys_for_action({ ['o'] = 'toggle' }, 'quit'))
    assert.equals('', mappings.keys_for_action(false, 'toggle'))
  end)
end)

describe('mappings.help_lines', function()
  it('renders one section per context, key-aligned, omitting disabled actions', function()
    local cfg = config.resolve({
      drawer = { keys = { ['D'] = false } }, -- disable duplicate
    })
    local lines = mappings.help_lines(cfg)

    local function index_of(title)
      for i, l in ipairs(lines) do
        if l == title then
          return i
        end
      end
    end
    assert.is_truthy(index_of('Drawer'))
    assert.is_truthy(index_of('Query Buffer'))
    assert.is_truthy(index_of('DB Results'))
    assert.is_true(index_of('Drawer') < index_of('Query Buffer'))
    assert.is_true(index_of('Query Buffer') < index_of('DB Results'))

    local blob = table.concat(lines, '\n')
    assert.is_truthy(blob:find('Open/Toggle selected item', 1, true))
    assert.is_truthy(blob:find('Execute query', 1, true))
    -- The disabled action is gone.
    assert.is_falsy(blob:find('Duplicate connection', 1, true))
  end)

  it('shows a user action with its desc, after the built-ins', function()
    local cfg = config.resolve({
      drawer = { keys = { ['Y'] = 'yank_url' } },
      actions = { yank_url = { desc = 'Yank the connection URL', fn = function() end } },
    })
    local blob = table.concat(mappings.help_lines(cfg), '\n')
    assert.is_truthy(blob:find('Yank the connection URL', 1, true))
  end)

  it('drops a whole section when all its keys are disabled', function()
    local cfg = config.resolve({ results = { keys = false } })
    local lines = mappings.help_lines(cfg)
    assert.is_falsy(vim.tbl_contains(lines, 'DB Results'))
    assert.is_truthy(vim.tbl_contains(lines, 'Drawer'))
  end)
end)
