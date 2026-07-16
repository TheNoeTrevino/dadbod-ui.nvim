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

-- e2e fixtures beyond export ------------------------------------------------

-- orders: a foreign key onto people, for the FK-flavored table helpers and
-- foreign-key introspection (pragma_foreign_key_list reads the DDL even with
-- foreign_keys off).
DROP TABLE IF EXISTS orders;
CREATE TABLE orders (
    id INTEGER PRIMARY KEY,
    person_id INTEGER NOT NULL REFERENCES people (id),
    label TEXT
);
INSERT INTO orders (id, person_id, label) VALUES
(1, 1, 'first'),
(2, 2, 'second'),
(3, 2, 'third');

-- numbers: 250 rows -- more than one default 200-row page, so pagination has a
-- real page 2 to step onto.
DROP TABLE IF EXISTS numbers;
CREATE TABLE numbers (n INTEGER PRIMARY KEY);
INSERT INTO numbers
WITH RECURSIVE seq (n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 250
)
SELECT n FROM seq;
