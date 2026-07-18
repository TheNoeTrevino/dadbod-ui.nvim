-- Plain-SELECT / already-paged facts -- mariadb.
local cases = require('classifier.cases')
cases.run('mariadb', 'pagination', cases.pagination)
