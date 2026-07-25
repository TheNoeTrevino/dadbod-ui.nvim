-- Shared "nasty data" export fixture (DuckDB dialect). Mirrors
-- seed/postgres.sql and seed/sqlite.sql. Applied by run-suite.sh to a
-- throwaway temp db file (DuckDB, like SQLite, needs no container).
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS people;
CREATE TABLE people (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    note TEXT,
    amount DOUBLE
);

-- chr(10) = newline, chr(9) = tab (portable, no E-string escapes).
INSERT INTO people (id, name, note, amount) VALUES
(1, 'Ann', NULL, 10.5),
(2, 'O''Brien', 'has, comma', 20.0),
(3, 'Zoe', 'line1' || chr(10) || 'line2', 3.25),
(4, 'Ünïcödé', 'tab' || chr(9) || 'here & <b>', NULL);

-- e2e fixtures beyond export ------------------------------------------------

-- orders: a foreign key onto people, for the FK-flavored table helpers and
-- the foreign-key jump (duckdb_constraints() surfaces it). Dropped FIRST
-- above: DuckDB refuses to drop a table another table references.
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
INSERT INTO numbers SELECT * FROM generate_series(1, 250);

-- analytics: a second schema, so the schema tree has more than `main` to list.
CREATE SCHEMA IF NOT EXISTS analytics;
DROP TABLE IF EXISTS analytics.orders_archive;
CREATE TABLE analytics.orders_archive (id INTEGER PRIMARY KEY, label TEXT);
