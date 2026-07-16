-- Is the statement changing (does it mutate anything) -- sqlserver.
local cases = require('classifier.cases')
cases.run('sqlserver', 'changing', cases.changing)

cases.run('sqlserver', 'changing (dialect)', {
  {
    sql = 'SELECT [delete], [update] FROM t',
    expect = { is_changing = false },
    label = 'bracket-quoted identifiers are names, not keywords',
  },
  { sql = "EXEC sp_rename 'old', 'new'", expect = { is_changing = true } },
})
