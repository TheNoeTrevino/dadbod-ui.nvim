-- Plain-SELECT / already-paged facts -- mysql.
local cases = require('classifier.cases')
cases.run('mysql', 'pagination', cases.pagination)
