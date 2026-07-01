-- Shared "nasty data" export fixture (SQLite dialect). Mirrors
-- seed/postgres.sql and seed/mysql.sql. Applied by run.sh to a throwaway temp
-- db file (SQLite needs no container).
DROP TABLE IF EXISTS people;
CREATE TABLE people (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    note TEXT,
    amount REAL
);

-- char(10) = newline, char(9) = tab (SQLite has no C-style string escapes).
INSERT INTO people (id, name, note, amount) VALUES
(1, 'Ann', NULL, 10.5),
(2, 'O''Brien', 'has, comma', 20.0),
(3, 'Zoe', 'line1' || char(10) || 'line2', 3.25),
(4, 'Ünïcödé', 'tab' || char(9) || 'here & <b>', NULL);
