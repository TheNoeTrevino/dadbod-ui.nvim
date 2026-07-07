-- MariaDB: mysql's spec with its own executing-EXPLAIN form
--
-- The wire behavior (mysql client, introspection SQL, helpers, pagination,
-- export flags) is mysql's; only the analyze template differs -- MariaDB spells
-- its executing form `ANALYZE <stmt>` (no `EXPLAIN` prefix). A distinct adapter
-- (not an alias) so user `table_helpers.mariadb` overrides stay scoped to
-- mariadb connections, matching the pre-registry behavior.

---@private
local mysql = require('dadbod-ui.adapters.mysql')

---@type DadbodUI.Adapter
return vim.tbl_extend('force', {}, mysql, {
  name = 'mariadb',
  explain = { plain = 'EXPLAIN {sql}', analyze = 'ANALYZE {sql}' },
})
