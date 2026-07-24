# Script As (DDL scripting)

Like SSMS. A routine or table node in the drawer expands to a "Script As"
submenu (CREATE / ALTER / DROP / SELECT / ...). Picking one builds the DDL and
puts it in a query buffer. You get prompted for where: new buffer, replace, or
append.

## Where the code lives

- [`lua/dadbod-ui/script_as.lua`](../lua/dadbod-ui/script_as.lua)
  owns the prompt, the fetch and the hand off. No SQL in there, and it never
  branches on object kind.
- The actions live on the adapter spec as `routine_scripts.actions` (routines)
  and `table_scripts.actions` (tables). Each one is
  `{ label, query?, args?, parse?, build? }`:
  - `query(schema, name, kind)` - sql that fetches the input. Leave it off
    when the name alone is enough (DROP doesnt need a round trip)
  - `args` - CLI args for this fetch, when the defaults dont fit
  - `parse(lines)` - raw output into whatever `build` wants
  - `build(ctx)` - the final DDL from `{ schema, name, kind, data }`; nil
    means "could not script" (e.g. an unknown table)

An adapter opts in by defining the capability. Nothing else changes. A table's
Script As node renders ahead of its helper leaves (the helper order is user
configurable, the submenu spot is not).

## Routines, implemented today

| Adapter    | Actions | How                                                                                           |
| ---------- | ------- | --------------------------------------------------------------------------------------------- |
| PG         | 4       | Server built: `pg_get_functiondef` + `pg_get_function_identity_arguments`, no Lua string work |
| SQL Server | 6       | Fetches `sys.sql_modules.definition`, assembles in Lua                                        |

PG has fewer actions because it has no CREATE vs ALTER split for routine
bodies. You redefine with `CREATE OR REPLACE`, `ALTER FUNCTION` only touches
attributes.

## Close to free, not done yet

MySQL / MariaDB give the routine DDL back in one query with
`SHOW CREATE PROCEDURE` / `SHOW CREATE FUNCTION`. Oracle has
`DBMS_METADATA.GET_DDL`. Tracked in #95.

## Tables, implemented today (#90)

Every ported adapter exposes the same six actions: `CREATE To`, `DROP To`,
`SELECT To`, `INSERT To`, `UPDATE To`, `DELETE To`. Shared conventions:

- values are `:name` bind placeholders with the type as a trailing comment
  (running the statement prompts for each), like the routine `EXECUTE To`
- `INSERT To` / `UPDATE To` exclude server-supplied columns (identity /
  auto-increment, generated / computed, rowversion)
- `UPDATE To` / `DELETE To` key their WHERE on the primary key; a PK-less
  table gets a `<condition>` placeholder instead
- `DROP To` builds from the name alone, no round trip

| Adapter         | Column-list actions                            | `CREATE To`                                                                                                     |
| --------------- | ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| PG              | Server built over `pg_attribute`, one query    | Server built: columns + identity/generated/defaults, constraints via `pg_get_constraintdef`, `pg_get_indexdef`  |
| MySQL / MariaDB | Fetch `information_schema.columns`, Lua builds | `SHOW CREATE TABLE`, returned verbatim                                                                          |
| SQL Server      | Fetch `sys.columns`, Lua builds                | Server renders each line from the `sys.*` catalogs as marker rows (STRING_AGG, 2017+); Lua joins them           |

The hand-assembled `CREATE To` (pg, sqlserver) is good-enough by design, per
the phasing on [#90](https://github.com/TheNoeTrevino/dadbod-ui.nvim/issues/90):
column definitions, PK / unique / check / FK constraints and secondary indexes
(constraint-backed ones excluded). Deliberately out of scope: partitioning,
storage parameters / filegroups, collations, compression, triggers,
inheritance. Two honest quirks: pg serial columns render as their
`DEFAULT nextval(...)` truth (identity columns render properly), and a pg
view/matview node scripts as a plain CREATE TABLE snapshot of its shape.

SQLite, ClickHouse and Oracle tables are not ported yet -- the first two hand
back `CREATE TABLE` in one query, Oracle has `DBMS_METADATA.GET_DDL`.
