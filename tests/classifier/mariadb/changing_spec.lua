-- Is the statement changing (does it mutate anything) -- mariadb.
local cases = require('classifier.cases')
cases.run('mariadb', 'changing', cases.changing)

cases.run('mariadb', 'changing (dialect)', {
  {
    sql = 'SELECT `delete`, `update` FROM t',
    expect = { is_changing = false },
    label = 'backtick-quoted identifiers are names, not keywords',
  },
  { sql = 'REPLACE INTO t VALUES (1)', expect = { is_changing = true } },
})
