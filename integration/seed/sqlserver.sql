-- Shared e2e fixture (SQL Server dialect). Applied with sqlcmd INSIDE the
-- container (run.sh). GO separators: sqlcmd batches.
IF DB_ID('dbui') IS NULL CREATE DATABASE dbui;
GO
USE dbui;
GO
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS people;
CREATE TABLE people (
    id int PRIMARY KEY,
    name nvarchar(255) NOT NULL,
    note nvarchar(max),
    amount decimal(10, 2)
);
INSERT INTO people (id, name, note, amount) VALUES
(1, N'Ann', NULL, 10.50),
(2, N'O''Brien', N'has, comma', 20.00),
(3, N'Zoe', N'line one', 3.25),
(4, N'Ünïcödé', N'tab here & <b>', NULL);

CREATE TABLE orders (
    id int PRIMARY KEY,
    person_id int NOT NULL FOREIGN KEY REFERENCES people (id),
    label nvarchar(64)
);
INSERT INTO orders (id, person_id, label) VALUES
(1, 1, N'first'),
(2, 2, N'second'),
(3, 2, N'third');

-- 250 rows: more than one default 200-row page. Recursive CTE needs the
-- MAXRECURSION bump past the default 100.
DROP TABLE IF EXISTS numbers;
CREATE TABLE numbers (n int PRIMARY KEY);
WITH seq (n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 250
)
INSERT INTO numbers (n)
SELECT n FROM seq
OPTION (MAXRECURSION 300);
GO
DROP PROCEDURE IF EXISTS greet;
GO
CREATE PROCEDURE greet AS SELECT 'hello' AS greeting;
GO
