-- Plain-SELECT / already-paged facts -- sqlite.
local cases = require('classifier.cases')
cases.run('sqlite', 'pagination', cases.pagination)
