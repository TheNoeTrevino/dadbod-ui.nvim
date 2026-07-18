-- Plain-SELECT / already-paged facts -- postgres.
local cases = require('classifier.cases')
cases.run('postgres', 'pagination', cases.pagination)
