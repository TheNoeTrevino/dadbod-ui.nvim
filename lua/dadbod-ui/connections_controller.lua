-- Interactive connections.json CRUD
--
-- Wires the drawer's add/delete/rename/duplicate/group/move keys to the pure
-- CRUD transforms in
-- `dadbod-ui.connections`. Each flow prompts through an injectable `input`
-- (vim.ui.input by default, callback-shaped), routes user-facing messages
-- through the notifications layer, and on success writes connections.json,
-- re-discovers, and re-renders via the injected render callback. It operates on
-- the instance plus the pure transforms, so it requires neither `drawer` nor
-- `query` and keeps `state` the dependency sink.

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
--- `(nil, err)` when dadbod rejects it. The resolved value is for validation
--- (and deriving a default name) only -- callers persist the RAW typed url so
--- env-var references like `$DB_PASS` stay unexpanded on disk: the url is
--- validated via `db#url#parse`, but the RAW typed url is what gets saved.
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

---@private
--- Guard a mutation to a persistable connection: only `file`-source entries live
--- in connections.json, so variable/env/dotenv connections can't be edited and
--- are refused with a notification. Returns true when `entry` is safe to mutate.
---@param entry DadbodUI.ConnectionEntry
---@param verb string  the refused action, for the message ('edit' | 'move' | 'delete')
---@return boolean
local function require_file_source(entry, verb)
  if entry.source == 'file' then
    return true
  end
  require('dadbod-ui.notifications').error(string.format('Cannot %s connections added via variables.', verb))
  return false
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
    return notify.error('Please set up a valid save location via setup({ save_location = ... })')
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
      -- Persist the RAW url the user typed, not the resolved one: resolving
      -- expands `$DB_PASS`-style env references, which would write plaintext
      -- secrets to disk and freeze the value against later rotation. We only
      -- resolve to validate (above); the store keeps the typed url.
      local list, add_err = connections.add_connection(store, name, url)
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
  if not require_file_source(entry, 'edit') then
    return
  end
  local notify = require('dadbod-ui.notifications')
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
        -- Persist the raw typed url (see validate_url); pass entry.group so the
        -- right clone is located when a same (name, url) exists in two groups.
        local list, rename_err = connections.rename_connection(store, entry.name, entry.url, name, url, entry.group)
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
    return notify.error('Please set up a valid save location via setup({ save_location = ... })')
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
        -- Persist the raw typed url (see validate_url), not the resolved one.
        local list, dup_err = connections.duplicate_connection(store, name, url, group)
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
  if not require_file_source(entry, 'edit') then
    return
  end
  local notify = require('dadbod-ui.notifications')
  self.input({ prompt = 'Enter group name: ', default = entry.group }, function(group)
    if group == nil then
      return
    end
    group = vim.trim(group)
    local store = self:read_store()
    if store == nil then
      return
    end
    -- Pass entry.group as the CURRENT group so the right clone is located when a
    -- same (name, url) exists in two groups; `group` is the new target group.
    local list, err = connections.set_group(store, entry.name, entry.url, group, entry.group)
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
  if not require_file_source(entry, 'move') then
    return
  end
  local notify = require('dadbod-ui.notifications')
  local store = self:read_store()
  if store == nil then
    return
  end
  -- Pass entry.group so the right clone is located when a same (name, url)
  -- exists in two groups.
  local list, err = connections.move_connection(store, entry.name, entry.url, direction, entry.group)
  if list == nil then
    return notify.error(err or 'Could not move connection.')
  end
  self:commit_connections(list)
end

--- Confirm, then remove a file-source connection. Only file-source connections
--- are deletable; discovered ones (g:dbs/env/dotenv) are refused with a
--- notification (mirroring the `rename`/`set_group`/`move` guards) -- otherwise
--- deleting one would silently rewrite connections.json and could drop an
--- unrelated file entry sharing its name+url.
---@param entry DadbodUI.ConnectionEntry
---@return nil
function Controller:delete_connection(entry)
  if not require_file_source(entry, 'delete') then
    return
  end
  if not self.confirm(string.format('Are you sure you want to delete connection %s?', entry.name)) then
    return
  end
  local store = self:read_store()
  if store == nil then
    return
  end
  -- Pass entry.group so only the targeted clone is removed when a same
  -- (name, url) exists in two groups.
  local list = connections.delete_connection(store, entry.name, entry.url, entry.group)
  self:commit_connections(list)
end

M.Controller = Controller
return M
