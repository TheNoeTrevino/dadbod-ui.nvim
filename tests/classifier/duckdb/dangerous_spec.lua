-- Is the statement dangerous (DROP/TRUNCATE, UPDATE/DELETE sans WHERE) -- duckdb.
local cases = require('classifier.cases')
cases.run('duckdb', 'dangerous', cases.dangerous)
