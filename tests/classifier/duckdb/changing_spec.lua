-- Is the statement changing (does it mutate anything) -- duckdb.
local cases = require('classifier.cases')
cases.run('duckdb', 'changing', cases.changing)
