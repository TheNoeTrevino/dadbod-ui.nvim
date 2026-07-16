-- Is the statement changing (does it mutate anything) -- postgres.
local cases = require('classifier.cases')
cases.run('postgres', 'changing', cases.changing)

cases.run('postgres', 'changing (dialect)', {
  {
    sql = 'SELECT "delete", "drop" FROM t',
    expect = { is_changing = false },
    label = 'double-quoted identifiers are names, not keywords',
  },
})
