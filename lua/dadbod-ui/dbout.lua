---@mod dadbod-ui.dbout  Result buffers: in-buffer loading spinner + result list
---
--- Drives the `.dbout` result buffers that dadbod produces. dadbod opens the
--- (empty) output buffer in a preview window and fires `*DBExecutePre`, runs the
--- query asynchronously, reloads the file with rows, then fires `*DBExecutePost`.
--- We hook those events to animate a loading spinner *inside* the output buffer
--- while the query runs (replaced by the rows on completion), and we record each
--- executed result under the drawer's `Query results` section.
---
--- This deviates from the original on the loading symbol only: vim-dadbod-ui
--- shows a floating progress window, whereas we animate a braille `dots12`
--- spinner in the buffer itself. Both are gated by `disable_progress_bar`.

local bridge = require('dadbod-ui.bridge')

local M = {}

-- The braille `dots12` spinner: 56 frames cycled every 80ms.
local SPINNER = {
  interval = 80,
  frames = {
    '⢀⠀', '⡀⠀', '⠄⠀', '⢂⠀', '⡂⠀', '⠅⠀', '⢃⠀', '⡃⠀',
    '⠍⠀', '⢋⠀', '⡋⠀', '⠍⠁', '⢋⠁', '⡋⠁', '⠍⠉', '⠋⠉',
    '⠋⠉', '⠉⠙', '⠉⠙', '⠉⠩', '⠈⢙', '⠈⡙', '⢈⠩', '⡀⢙',
    '⠄⡙', '⢂⠩', '⡂⢘', '⠅⡘', '⢃⠨', '⡃⢐', '⠍⡐', '⢋⠠',
    '⡋⢀', '⠍⡁', '⢋⠁', '⡋⠁', '⠍⠉', '⠋⠉', '⠋⠉', '⠉⠙',
    '⠉⠙', '⠉⠩', '⠈⢙', '⠈⡙', '⠈⠩', '⠀⢙', '⠀⡙', '⠀⠩',
    '⠀⢘', '⠀⡘', '⠀⠨', '⠀⢐', '⠀⡐', '⠀⠠', '⠀⢀', '⠀⡀',
  },
}

-- output_file -> { timer = uv_timer, buf = integer, frame = integer }
local spinners = {}

-- The drawer this module re-renders through; set on attach.
---@type DadbodUI.Drawer|nil
local attached = nil

-- True once the session autocmds / event subscriptions are registered.
local registered = false

--- The spinner line for `frame`.
---@param frame integer
---@return string
local function spinner_line(frame)
  return ' ' .. SPINNER.frames[frame] .. ' Executing query...'
end

--- Stop and forget the spinner for `output_file`, if any.
---@param output_file string
---@return nil
local function stop_spinner(output_file)
  local s = spinners[output_file]
  if s == nil then
    return
  end
  spinners[output_file] = nil
  pcall(function()
    s.timer:stop()
    if not s.timer:is_closing() then
      s.timer:close()
    end
  end)
end

--- Write the current frame into the output buffer (which dadbod leaves
--- `nomodifiable`, so we flip it for the write). dadbod's reload discards these
--- buffer-only edits when the rows arrive.
---@param output_file string
---@return nil
local function paint(output_file)
  local s = spinners[output_file]
  if s == nil then
    return
  end
  if not vim.api.nvim_buf_is_valid(s.buf) then
    return stop_spinner(output_file)
  end
  vim.bo[s.buf].modifiable = true
  pcall(vim.api.nvim_buf_set_lines, s.buf, 0, -1, false, { spinner_line(s.frame) })
  s.frame = s.frame % #SPINNER.frames + 1
end

--- Start animating the loading spinner in the result buffer for `output_file`.
--- No-op when the progress bar is disabled or the output buffer is not open yet.
---@param output_file string
---@return nil
function M._show(output_file)
  if attached == nil or attached.config.disable_progress_bar then
    return
  end
  local buf = vim.fn.bufnr(output_file)
  if buf < 0 then
    return
  end
  stop_spinner(output_file)
  local timer = vim.uv.new_timer()
  if timer == nil then
    return
  end
  spinners[output_file] = { timer = timer, buf = buf, frame = 1 }
  paint(output_file)
  timer:start(
    SPINNER.interval,
    SPINNER.interval,
    vim.schedule_wrap(function()
      paint(output_file)
    end)
  )
end

--- Stop the spinner for `output_file` (dadbod has reloaded the rows by now).
---@param output_file string
---@return nil
function M._hide(output_file)
  stop_spinner(output_file)
end

--- Record an executed result file under the drawer's `Query results` section and
--- re-render. The preview content is the first line of the query input (the
--- statement that produced it), truncated. Port of `s:dbui.save_dbout`.
---@param file string  the .dbout result file path
---@return nil
function M.save_dbout(file)
  if attached == nil then
    return
  end
  local list = attached.instance.dbout_list
  if list[file] ~= nil and list[file] ~= '' then
    return
  end
  local content = ''
  local db = vim.fn.getbufvar(file, 'db')
  local input = type(db) == 'table' and db.input or nil
  if input ~= nil and input ~= '' and vim.fn.filereadable(input) == 1 then
    content = (vim.fn.readfile(input, '', 1)[1]) or ''
    if #content > 30 then
      content = content:sub(1, 31) .. '...'
    end
  end
  list[file] = content
  attached:render()
end

--- Comparator for result files in the `Query results` section: numeric by
--- basename, ascending or descending per `dbout_list_sort`. Port of
--- `s:sort_dbout`.
---@param a string
---@param b string
---@return boolean
function M.sort_dbout(a, b)
  local na = tonumber(vim.fn.fnamemodify(a, ':t:r')) or 0
  local nb = tonumber(vim.fn.fnamemodify(b, ':t:r')) or 0
  if attached ~= nil and attached.config.dbout_list_sort == 'desc' then
    return na > nb
  end
  return na < nb
end

--- Register the session-wide autocmds and bridge subscriptions once: `.dbout`
--- filetype, result recording on read, and the loading spinner on the async
--- execute events. Idempotent; remembers `drawer` for re-rendering.
---@param drawer DadbodUI.Drawer
---@return nil
function M.attach(drawer)
  attached = drawer
  if registered then
    return
  end
  registered = true
  local group = vim.api.nvim_create_augroup('dadbod_ui_dbout', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufRead', 'BufNewFile' }, {
    group = group,
    pattern = '*.dbout',
    callback = function()
      vim.bo.filetype = 'dbout'
    end,
  })
  vim.api.nvim_create_autocmd('BufReadPost', {
    group = group,
    pattern = '*.dbout',
    callback = function(args)
      M.save_dbout(args.match)
    end,
  })
  bridge.on_pre(function(info)
    M._show(info.output_file)
  end, { group = group })
  bridge.on_post(function(info)
    M._hide(info.output_file)
  end, { group = group })
end

return M
