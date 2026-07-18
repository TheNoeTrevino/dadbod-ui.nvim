-- Plain-SELECT / already-paged facts -- sqlserver.
local cases = require('classifier.cases')
cases.run('sqlserver', 'pagination', cases.pagination)

cases.run('sqlserver', 'pagination (dialect)', {
  { sql = 'SELECT TOP 10 * FROM t', expect = { is_plain_select = true, is_paginated = true } },
})
