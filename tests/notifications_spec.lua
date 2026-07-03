local notifications = require('dadbod-ui.notifications')
local state = require('dadbod-ui.state')

describe('notifications', function()
  local notify_calls, echo_calls
  local saved_notify, saved_echo, saved_confirm

  before_each(function()
    notify_calls, echo_calls = {}, {}
    saved_notify = vim.notify
    saved_echo = vim.api.nvim_echo
    saved_confirm = vim.fn.confirm
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level, opts)
      table.insert(notify_calls, { msg = msg, level = level, opts = opts })
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.api.nvim_echo = function(chunks, history, opts)
      table.insert(echo_calls, { chunks = chunks, history = history, opts = opts })
    end
  end)

  after_each(function()
    vim.notify = saved_notify
    vim.api.nvim_echo = saved_echo
    vim.fn.confirm = saved_confirm
    state.reset()
  end)

  it('routes info/warn/error through vim.notify with the [DBUI] title', function()
    state.setup({})
    notifications.info('hello')
    notifications.warn('careful')
    notifications.error('boom')

    assert.equals(3, #notify_calls)
    assert.equals('hello', notify_calls[1].msg)
    assert.equals(vim.log.levels.INFO, notify_calls[1].level)
    assert.equals('[DBUI]', notify_calls[1].opts.title)
    assert.equals(vim.log.levels.WARN, notify_calls[2].level)
    assert.equals(vim.log.levels.ERROR, notify_calls[3].level)
  end)

  it('ignores empty messages', function()
    state.setup({})
    notifications.info('')
    notifications.info(nil)
    notifications.error({})
    assert.equals(0, #notify_calls)
  end)

  it('suppresses info when disable_info_notifications is set', function()
    state.setup({ disable_info_notifications = true })
    notifications.info('quiet')
    notifications.warn('still here')
    notifications.error('still here')

    assert.equals(2, #notify_calls)
    assert.equals(vim.log.levels.WARN, notify_calls[1].level)
    assert.equals(vim.log.levels.ERROR, notify_calls[2].level)
  end)

  it('uses the echo backend when force_echo_notifications is set', function()
    state.setup({ force_echo_notifications = true })
    notifications.error('boom')

    assert.equals(0, #notify_calls)
    assert.equals(1, #echo_calls)
    assert.equals('[DBUI] boom', echo_calls[1].chunks[1][1])
    assert.equals('ErrorMsg', echo_calls[1].chunks[1][2])
    assert.is_true(echo_calls[1].history)
  end)

  it('lets a per-call echo opt force the echo backend', function()
    state.setup({})
    notifications.info('cmdline', { echo = true })

    assert.equals(0, #notify_calls)
    assert.equals(1, #echo_calls)
    assert.equals('[DBUI] cmdline', echo_calls[1].chunks[1][1])
  end)

  it('joins list messages with newlines', function()
    state.setup({})
    notifications.warn({ 'line one', 'line two' })

    assert.equals('line one\nline two', notify_calls[1].msg)
    assert.equals('line one\nline two', notifications.get_last_msg())
  end)

  it('records the last shown message', function()
    state.setup({})
    notifications.info('first')
    notifications.error('second')
    assert.equals('second', notifications.get_last_msg())
  end)

  it('does not record suppressed info as the last message', function()
    state.setup({ disable_info_notifications = true })
    notifications.error('shown')
    notifications.info('hidden')
    assert.equals('shown', notifications.get_last_msg())
  end)

  it('honors a per-call title and delay timeout', function()
    state.setup({})
    notifications.info('msg', { title = '[QA]', delay = 5000 })
    assert.equals('[QA]', notify_calls[1].opts.title)
    assert.equals(5000, notify_calls[1].opts.timeout)
  end)

  it('replaces info toasts under use_nvim_notify', function()
    state.setup({ use_nvim_notify = true })
    notifications.info('a')
    notifications.error('b')
    assert.equals('dadbod-ui-info', notify_calls[1].opts.id)
    assert.is_nil(notify_calls[2].opts.id)
  end)

  it('confirm returns true only on a Yes selection', function()
    state.setup({})
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.confirm = function()
      return 1
    end
    assert.is_true(notifications.confirm('Delete it?'))
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.confirm = function()
      return 2
    end
    assert.is_false(notifications.confirm('Delete it?'))
  end)
end)
