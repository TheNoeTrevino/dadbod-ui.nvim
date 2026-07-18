-- Is the statement dangerous (DROP/TRUNCATE, UPDATE/DELETE sans WHERE) -- postgres.
local cases = require('classifier.cases')
cases.run('postgres', 'dangerous', cases.dangerous)
