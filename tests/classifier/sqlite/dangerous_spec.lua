-- Is the statement dangerous (DROP/TRUNCATE, UPDATE/DELETE sans WHERE) -- sqlite.
local cases = require('classifier.cases')
cases.run('sqlite', 'dangerous', cases.dangerous)
