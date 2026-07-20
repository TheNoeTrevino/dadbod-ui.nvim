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
  explain = {
    plain = 'EXPLAIN {sql}',
    analyze = 'ANALYZE {sql}',
    json = 'EXPLAIN FORMAT=JSON {sql}',
    -- MariaDB (unlike MySQL) has an executing JSON form with real r_* timings.
    json_analyze = 'ANALYZE FORMAT=JSON {sql}',
    json_args = { '--batch', '--raw', '--skip-column-names' },
    -- Same query_block shape as MySQL; one normalizer reads both spellings.
    parser = 'dadbod-ui.explain.parsers.mysql',
  },
})
