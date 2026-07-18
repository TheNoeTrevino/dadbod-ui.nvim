-- MongoDB: table helpers only
--
-- No SQL introspection, explain, pagination, or export -- dadbod's mongodb
-- adapter runs shell-syntax commands, so the lone helper is a `find()` call.

---@type DadbodUI.Adapter
return {
  name = 'mongodb',
  table_helpers = { List = '{table}.find()' },
  -- Deliberately NO `statements` field: mongodb isn't SQL, so the statement
  -- classifier answers "cannot tell" for it rather than guessing.
}
