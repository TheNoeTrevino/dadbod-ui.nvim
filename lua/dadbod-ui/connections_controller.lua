---@mod dadbod-ui.connections_controller  Interactive connections.json CRUD
---
--- Wires the drawer's add/delete/rename/duplicate/group/move keys to the pure
--- CRUD transforms in
--- `dadbod-ui.connections`. Each flow prompts through an injectable `input`
--- (vim.ui.input by default, callback-shaped), routes user-facing messages
--- through the notifications layer, and on success writes connections.json,
--- re-discovers, and re-renders via the injected render callback. It operates on
--- the instance plus the pure transforms, so it requires neither `drawer` nor
--- `query` and keeps `state` the dependency sink.

---@alias DadbodUI.ConnectionsControllerOpts { instance: DadbodUI.Instance, input: DadbodUI.UiInput, confirm: DadbodUI.Confirm, render: fun() }

---@class DadbodUI.ConnectionsControllerModule
---@field new fun(opts: DadbodUI.ConnectionsControllerOpts): DadbodUI.ConnectionsController
---@field Controller DadbodUI.ConnectionsController

---@private
local connections = require('dadbod-ui.connections')
---@private
local bridge = require('dadbod-ui.bridge')

---@type DadbodUI.ConnectionsControllerModule
---@diagnostic disable-next-line: missing-fields
local M = {}

---@private
--- Resolve and validate a url the user typed. Returns `(resolved, nil)` or
--- `(nil, err)` when dadbod rejects it.
---@param url string
---@return string|nil, string|nil
local function validate_url(url)
  local ok, result = pcall(function()
    local resolved = bridge.resolve(url)
    bridge.parse_url(resolved)
    return resolved
  end)
  if not ok then
    return nil, tostring(result)
  end
  return result, nil
end

---@class DadbodUI.ConnectionsController
---@field instance DadbodUI.Instance
---@field input DadbodUI.UiInput  prompt backend (injectable for specs)
---@field confirm DadbodUI.Confirm  yes/no backend (injectable for specs)
---@field render fun(): nil  re-render callback (the drawer's render)
local Controller = {}
Controller.__index = Controller

--- Build a connections controller.
---@param opts { instance: DadbodUI.Instance, input: DadbodUI.UiInput, confirm: DadbodUI.Confirm, render: fun(): nil }
---@return DadbodUI.ConnectionsController
function M.new(opts)
  return setmetatable({
    instance = opts.instance,
    input = opts.input,
    confirm = opts.confirm,
    render = opts.render,
  }, Controller)
end

--- Read the connections.json store, refusing to proceed when it is present but
--- corrupt -- so a CRUD action can't silently overwrite a file we failed to
--- parse. Returns the list, or nil when the store is unreadable.
---@return DadbodUI.FileConnection[]|nil
function Controller:read_store()
  local corrupt = false
  local list = connections.read_file(self.instance.connections_path, function()
    corrupt = true
  end)
  if corrupt then
    require('dadbod-ui.notifications').error(
      'Could not read connections file; refusing to overwrite it. Fix or remove: '
        .. (self.instance.connections_path or '')
    )
    return nil
  end
  return list
end

--- Persist `connections.json`, re-discover, and re-render.
---@param list DadbodUI.FileConnection[]
---@return nil
function Controller:commit_connections(list)
  local path = self.instance.connections_path
  if path == nil then
    return
  end
  connections.write_file(path, list)
  self.instance:repopulate()
  self.render()
end

--- Add a new file-source connection (also `:DBUIAddConnection`). Prompts for a
--- url then a name; rejects an invalid url, a blank name, or a duplicate name.
---@return nil
function Controller:add_connection()
  local notify = require('dadbod-ui.notifications')
  if self.instance.connections_path == nil then
    return notify.error('Please set up valid save location via g:db_ui_save_location')
  end
  self.input({ prompt = 'Enter connection url: ' }, function(url)
    if url == nil then
      return
    end
    local resolved, err = validate_url(url)
    if resolved == nil then
      return notify.error(err or 'Invalid connection url.')
    end
    self.input({ prompt = 'Enter name: ', default = resolved:match('[^/]*$') }, function(name)
      if name == nil then
        return
      end
      name = vim.trim(name)
      if name == '' then
        return notify.error('Please enter valid name.')
      end
      local store = self:read_store()
      if store == nil then
        return
      end
      local list, add_err = connections.add_connection(store, name, resolved)
      if list == nil then
        return notify.error(add_err or 'Could not add connection.')
      end
      self:commit_connections(list)
      notify.info('Saved connection.')
    end)
  end)
end

--- Rename/edit a connection. Only file-source connections are editable; others
--- are refused with a notification. Prompts for a new url then a new name.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Controller:rename_connection(entry)
  local notify = require('dadbod-ui.notifications')
  if entry.source ~= 'file' then
    return notify.error('Cannot edit connections added via variables.')
  end
  self.input(
    { prompt = string.format('Edit connection url for "%s": ', entry.name), default = entry.url },
    function(url)
      if url == nil then
        return
      end
      local resolved, err = validate_url(url)
      if resolved == nil then
        return notify.error(err or 'Invalid connection url.')
      end
      self.input({ prompt = 'Edit connection name: ', default = entry.name }, function(name)
        if name == nil then
          return
        end
        name = vim.trim(name)
        if name == '' then
          return notify.error('Please enter valid name.')
        end
        local store = self:read_store()
        if store == nil then
          return
        end
        local list, rename_err = connections.rename_connection(store, entry.name, entry.url, name, resolved)
        if list == nil then
          return notify.error(rename_err or 'Could not rename connection.')
        end
        self:commit_connections(list)
      end)
    end
  )
end

--- Duplicate a connection into the file store (`D`). Prompts for a name
--- (prefilled from the source), a url (prefilled from the source), then a group
--- (prefilled from the source). Because the same name is allowed in different
--- groups, the natural clone is "keep the name, change the group" -- e.g.
--- `geekom/postgres` -> `pi/postgres`. Works on any source: the result is always
--- a file connection, so a `g:dbs`/env entry can be cloned into an editable one.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Controller:duplicate_connection(entry)
  local notify = require('dadbod-ui.notifications')
  if self.instance.connections_path == nil then
    return notify.error('Please set up valid save location via g:db_ui_save_location')
  end
  self.input({ prompt = 'Enter name for the duplicate: ', default = entry.name }, function(name)
    if name == nil then
      return
    end
    name = vim.trim(name)
    if name == '' then
      return notify.error('Please enter valid name.')
    end
    self.input({ prompt = 'Enter connection url: ', default = entry.url }, function(url)
      if url == nil then
        return
      end
      local resolved, err = validate_url(url)
      if resolved == nil then
        return notify.error(err or 'Invalid connection url.')
      end
      self.input({ prompt = 'Enter group (optional): ', default = entry.group }, function(group)
        if group == nil then
          return
        end
        group = vim.trim(group)
        local store = self:read_store()
        if store == nil then
          return
        end
        local list, dup_err = connections.duplicate_connection(store, name, resolved, group)
        if list == nil then
          return notify.error(dup_err or 'Could not duplicate connection.')
        end
        self:commit_connections(list)
        notify.info('Duplicated connection.')
      end)
    end)
  end)
end

--- Assign a connection to a group (or clear it). A group is just a shared name:
--- entering an existing group joins it, a new name creates it, and an empty
--- entry ungroups. Only file-source connections are editable.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Controller:set_group(entry)
  local notify = require('dadbod-ui.notifications')
  if entry.source ~= 'file' then
    return notify.error('Cannot edit connections added via variables.')
  end
  self.input({ prompt = 'Enter group name: ', default = entry.group }, function(group)
    if group == nil then
      return
    end
    group = vim.trim(group)
    local store = self:read_store()
    if store == nil then
      return
    end
    local list, err = connections.set_group(store, entry.name, entry.url, group)
    if list == nil then
      return notify.error(err or 'Could not set group.')
    end
    self:commit_connections(list)
  end)
end

--- Move a file connection one slot up or down in the drawer's visual order,
--- crossing group boundaries (see `connections.move_connection`). Only file-source
--- connections are persistable; discovered ones are refused with a notification
--- (mirroring the `set_group`/`rename` guards).
---@param entry DadbodUI.ConnectionEntry
---@param direction 'up'|'down'
---@return nil
function Controller:move_connection(entry, direction)
  local notify = require('dadbod-ui.notifications')
  if entry.source ~= 'file' then
    return notify.error('Cannot move connections added via variables.')
  end
  local store = self:read_store()
  if store == nil then
    return
  end
  local list, err = connections.move_connection(store, entry.name, entry.url, direction)
  if list == nil then
    return notify.error(err or 'Could not move connection.')
  end
  self:commit_connections(list)
end

--- Confirm, then remove a file-source connection.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Controller:delete_connection(entry)
  if not self.confirm(string.format('Are you sure you want to delete connection %s?', entry.name)) then
    return
  end
  local store = self:read_store()
  if store == nil then
    return
  end
  local list = connections.delete_connection(store, entry.name, entry.url)
  self:commit_connections(list)
end

M.Controller = Controller
return M
