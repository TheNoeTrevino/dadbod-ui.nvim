-- Plain-SELECT / already-paged facts -- duckdb.
local cases = require('classifier.cases')
cases.run('duckdb', 'pagination', cases.pagination)
