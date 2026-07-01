-- Shared "nasty data" export fixture (postgres dialect). The same logical table
-- and rows exist in seed/mysql.sql and seed/sqlite.sql; per-adapter output
-- differences (e.g. NULL rendering, numeric formatting) are captured in the
-- per-adapter golden files, not smoothed over here.
--
-- Special characters are built with chr() concatenation, NOT E'\n' escape-strings:
-- an SQL auto-formatter lowercases E'...' to e '...' (a syntax error), so the
-- escape-free form keeps the fixture robust. chr(10) = newline, chr(9) = tab.
DROP TABLE IF EXISTS people;
CREATE TABLE people (
    id integer PRIMARY KEY,
    name text NOT NULL,
    note text,
    amount numeric(10, 2)
);

INSERT INTO people (id, name, note, amount) VALUES
(1, 'Ann', NULL, 10.50),
(2, 'O''Brien', 'has, comma', 20.00),
(3, 'Zoe', 'line1' || chr(10) || 'line2', 3.25),
(4, 'Ünïcödé', 'tab' || chr(9) || 'here & <b>', NULL);
