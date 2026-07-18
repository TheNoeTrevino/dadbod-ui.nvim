-- Is the statement dangerous -- clickhouse, which spells row deletion
-- `ALTER TABLE ... DELETE`. The shared core already covers it: DELETE with no
-- WHERE is dangerous whatever precedes it.
local cases = require('classifier.cases')
cases.run('clickhouse', 'dangerous', cases.dangerous)

cases.run('clickhouse', 'dangerous (dialect)', {
  { sql = 'ALTER TABLE t DELETE WHERE id = 1', expect = { is_changing = true, is_dangerous = false } },
  { sql = 'ALTER TABLE t DELETE', expect = { is_changing = true, is_dangerous = true } },
})
