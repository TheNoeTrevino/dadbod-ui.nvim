-- Connection-name resolution shared by the api namespaces
--
-- The single addressing scheme every api verb resolves names through; split
-- out so `dadbod-ui.api.buf` can resolve without requiring the whole facade.

local state = require('dadbod-ui.state')

--- Resolve a connection `name` to its entry. Accepts three forms, in order of
--- precedence:
---   * the full `key_name` (`{group}_{name}_{source}` when grouped, else
---     `{name}_{source}`) -- always unambiguous;
---   * `"{group}/{name}"` -- to pick a specific grouped connection when the bare
---     name is reused across groups;
---   * the bare display `name` -- resolves the first match, so prefer one of the
---     forms above when a name collides across groups.
---@param name string
---@return DadbodUI.ConnectionEntry|nil
return function(name)
  local instance = state.get()
  local list = instance.dbs_list
  -- Each form is tried as its OWN pass so precedence holds across the whole list:
  -- an exact key_name anywhere beats a bare-name match earlier in the list.
  -- Exact key_name: never ambiguous, so it wins.
  local record = vim.iter(list):find(function(r)
    return r.key_name == name
  end)
  -- `group/name`: the friendly disambiguator for a name reused across groups.
  local group, conn = name:match('^(.+)/(.+)$')
  if record == nil and group ~= nil then
    record = vim.iter(list):find(function(r)
      return r.group == group and r.name == conn
    end)
  end
  -- Bare display name (first match; reached when `name` has no '/' or its
  -- group/name form matched nothing but the literal name still exists).
  if record == nil then
    record = vim.iter(list):find(function(r)
      return r.name == name
    end)
  end
  return record and instance.dbs[record.key_name] or nil
end
