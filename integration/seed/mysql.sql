-- Shared "nasty data" export fixture (MySQL / MariaDB dialect). Mirrors
-- seed/postgres.sql and seed/sqlite.sql. Used for BOTH the mysql:8.4 and
-- mariadb:11 servers -- server-level output differences are captured in the
-- separate mysql/ and mariadb/ golden directories.
--
-- Special characters are built with CHAR() concatenation, NOT backslash escapes,
-- so an SQL auto-formatter can't corrupt the fixture. CHAR(10) = newline,
-- CHAR(9) = tab.
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
