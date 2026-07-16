-- Shared "nasty data" export fixture (MySQL / MariaDB dialect). Mirrors
-- seed/postgres.sql and seed/sqlite.sql. Used for BOTH the mysql:8.4 and
-- mariadb:11 servers -- server-level output differences are captured in the
-- separate mysql/ and mariadb/ golden directories.
--
-- Special characters are built with CHAR() concatenation, NOT backslash escapes,
-- so an SQL auto-formatter can't corrupt the fixture. CHAR(10) = newline,
-- CHAR(9) = tab.
DROP TABLE IF EXISTS orders ; -- references people; drop the referrer first
DROP TABLE IF EXISTS people;
CREATE TABLE people (
    id INT PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    note TEXT,
    amount DECIMAL(10, 2)
) CHARACTER SET utf8mb4 ;

INSERT INTO people (id, name, note, amount) VALUES
(1, 'Ann', NULL, 10.50),
(2, 'O''Brien', 'has, comma', 20.00),
(3, 'Zoe', CONCAT ('line1', CHAR (10), 'line2'), 3.25),
(4, 'Ünïcödé', CONCAT ('tab', CHAR (9), 'here & <b>'), NULL) ;

-- e2e fixtures beyond export ------------------------------------------------

-- orders: a foreign key onto people, for the FK-flavored table helpers and
-- foreign-key introspection.
CREATE TABLE orders (
    id INT PRIMARY KEY,
    person_id INT NOT NULL,
    label VARCHAR(64),
    FOREIGN KEY (person_id) REFERENCES people (id)
) ;
INSERT INTO orders (id, person_id, label) VALUES
(1, 1, 'first'),
(2, 2, 'second'),
(3, 2, 'third') ;

-- numbers: 250 rows -- more than one default 200-row page, so pagination has a
-- real page 2 to step onto.
DROP TABLE IF EXISTS numbers ;
CREATE TABLE numbers (n INT PRIMARY KEY) ;
INSERT INTO numbers (n)
WITH RECURSIVE seq (n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 250
)
SELECT n FROM seq ;

-- a routine, so procedure introspection and definition fetch run against a
-- real catalog. A single-statement body needs no DELIMITER juggling when piped
-- through the client.
DROP PROCEDURE IF EXISTS greet ;
CREATE PROCEDURE greet () SELECT 'hello' AS greeting ;
