-- Is the statement dangerous (DROP/TRUNCATE, UPDATE/DELETE sans WHERE) -- sqlserver.
local cases = require('classifier.cases')
cases.run('sqlserver', 'dangerous', cases.dangerous)
