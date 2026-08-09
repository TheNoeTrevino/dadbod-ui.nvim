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
  -- mysql's explain spec (templates, json_args, the shared query_block
  -- parser), with MariaDB's executing forms on top: `ANALYZE <stmt>`, and --
  -- unlike MySQL -- an executing JSON form with real r_* timings.
  explain = vim.tbl_extend('force', {}, mysql.explain, {
    analyze = 'ANALYZE {sql}',
    json_analyze = 'ANALYZE FORMAT=JSON {sql}',
  }),
})
