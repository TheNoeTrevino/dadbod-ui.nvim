-- Shared e2e fixture (ClickHouse dialect). Mirrors the people/orders/numbers
-- shape of the other seeds. Applied with `clickhouse-client -n` INSIDE the
-- container (run.sh), so no host clickhouse client is needed for seeding.
DROP TABLE IF EXISTS people;
CREATE TABLE people (
    id Int32,
    name String,
    note Nullable(String),
    amount Nullable(Decimal(10, 2))
) ENGINE = MergeTree ORDER BY id;

INSERT INTO people (id, name, note, amount) VALUES
(1, 'Ann', NULL, 10.50),
(2, 'O''Brien', 'has, comma', 20.00),
(3, 'Zoe', 'line one', 3.25),
(4, 'Ünïcödé', 'tab here & <b>', NULL);

DROP TABLE IF EXISTS orders;
CREATE TABLE orders (
    id Int32,
    person_id Int32,
    label String
) ENGINE = MergeTree ORDER BY id;

INSERT INTO orders (id, person_id, label) VALUES
(1, 1, 'first'),
(2, 2, 'second'),
(3, 2, 'third');

-- 250 rows: more than one default 200-row page.
DROP TABLE IF EXISTS numbers;
CREATE TABLE numbers (n Int32) ENGINE = MergeTree ORDER BY n;
INSERT INTO numbers SELECT toInt32(number + 1) FROM system.numbers LIMIT 250;
