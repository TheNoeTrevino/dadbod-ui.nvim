-- Is the statement changing (does it mutate anything) -- sqlite.
local cases = require('classifier.cases')
cases.run('sqlite', 'changing', cases.changing)

cases.run('sqlite', 'changing (dialect)', {
  { sql = 'REPLACE INTO t VALUES (1)', expect = { is_changing = true } },
})
