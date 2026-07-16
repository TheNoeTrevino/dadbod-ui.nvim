-- Is the statement dangerous -- oracle, whose `statements` patterns extend the
-- SQL core with PURGE (bypasses the recycle bin: mutating AND destructive).
local cases = require('classifier.cases')
cases.run('oracle', 'dangerous', cases.dangerous)

cases.run('oracle', 'dangerous (dialect)', {
  { sql = 'PURGE RECYCLEBIN', expect = { is_changing = true, is_dangerous = true } },
  { sql = 'DROP TABLE t PURGE', expect = { is_dangerous = true } },
  {
    sql = "SELECT * FROM log WHERE msg = 'purge'",
    expect = { is_changing = false, is_dangerous = false },
    label = 'PURGE inside a string literal',
  },
})
