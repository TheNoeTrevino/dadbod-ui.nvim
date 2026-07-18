-- Shared "nasty data" export fixture (postgres dialect). The same logical table
-- and rows exist in seed/mysql.sql and seed/sqlite.sql; per-adapter output
-- differences (e.g. NULL rendering, numeric formatting) are captured in the
-- per-adapter golden files, not smoothed over here.
--
-- Special characters are built with chr() concatenation, NOT E'\n' escape-strings:
-- an SQL auto-formatter lowercases E'...' to e '...' (a syntax error), so the
-- escape-free form keeps the fixture robust. chr(10) = newline, chr(9) = tab.
-- The DROP ... IF EXISTS statements below are no-ops on a fresh container, and
-- psql announces each skip as a NOTICE. That is the seed being re-runnable, not
-- a problem -- but it buries the real output, so keep notices out of the log.
-- Warnings and errors still surface (psql also runs with ON_ERROR_STOP=1).
SET client_min_messages = warning;

DROP TABLE IF EXISTS orders; -- references people; drop the referrer first
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

-- e2e fixtures beyond export ------------------------------------------------

-- orders: a foreign key onto people, for the FK-flavored table helpers and
-- foreign-key introspection.
CREATE TABLE orders (
    id integer PRIMARY KEY,
    person_id integer NOT NULL REFERENCES people (id),
    label text
);
INSERT INTO orders (id, person_id, label) VALUES
(1, 1, 'first'),
(2, 2, 'second'),
(3, 2, 'third');

-- numbers: 250 rows -- more than one default 200-row page, so pagination has a
-- real page 2 to step onto.
DROP TABLE IF EXISTS numbers;
CREATE TABLE numbers (n integer PRIMARY KEY);
INSERT INTO numbers SELECT generate_series(1, 250);

-- a second schema, so schema introspection proves it lists more than public.
DROP SCHEMA IF EXISTS app CASCADE;
CREATE SCHEMA app;
CREATE TABLE app.orders_archive (id integer PRIMARY KEY, label text);
INSERT INTO app.orders_archive VALUES (1, 'old');

-- a routine, so procedure/function introspection and definition fetch run
-- against a real catalog. Body is a plain quoted string (no $$ dollar quoting:
-- an SQL auto-formatter can mangle it).
CREATE OR REPLACE FUNCTION greet (who text) RETURNS text
LANGUAGE sql
AS 'SELECT ''hello, '' || who';
