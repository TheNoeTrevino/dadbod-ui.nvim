-- Is the statement dangerous (DROP/TRUNCATE, UPDATE/DELETE sans WHERE) -- mariadb.
local cases = require('classifier.cases')
cases.run('mariadb', 'dangerous', cases.dangerous)
