-- Is the statement dangerous (DROP/TRUNCATE, UPDATE/DELETE sans WHERE) -- mysql.
local cases = require('classifier.cases')
cases.run('mysql', 'dangerous', cases.dangerous)
