# Script As (DDL scripting)

Like SSMS. A routine node in the drawer expands to a "Script As" submenu
(CREATE / ALTER / DROP / EXECUTE / ...). Picking one builds the DDL and puts
it in a query buffer. You get prompted for where: new buffer, replace, or
append.

## Where the code lives

- [`lua/dadbod-ui/routine_script.lua`](../lua/dadbod-ui/routine_script.lua)
  owns the prompt, the fetch and the hand off. No SQL in there, and it never
  branches on routine kind.
- The actions live on the adapter spec as `routine_scripts.actions`. Each one
  is `{ label, query?, args?, parse?, build? }`:
  - `query(schema, name, kind)` - sql that fetches the input. Leave it off
    when the name alone is enough (DROP doesnt need a round trip)
  - `args` - CLI args for this fetch, when the defaults dont fit
  - `parse(lines)` - raw output into whatever `build` wants
  - `build(ctx)` - the final DDL from `{ schema, name, kind, data }`

An adapter opts in by defining the capability. Nothing else changes.

## Implemented today

| Adapter    | Actions | How                                                                                           |
| ---------- | ------- | --------------------------------------------------------------------------------------------- |
| PG         | 4       | Server built: `pg_get_functiondef` + `pg_get_function_identity_arguments`, no Lua string work |
| SQL Server | 6       | Fetches `sys.sql_modules.definition`, assembles in Lua                                        |

PG has fewer actions because it has no CREATE vs ALTER split for routine
bodies. You redefine with `CREATE OR REPLACE`, `ALTER FUNCTION` only touches
attributes.

## Close to free, not done yet

MySQL / MariaDB give the DDL back in one query with `SHOW CREATE PROCEDURE` /
`SHOW CREATE FUNCTION`. Oracle has `DBMS_METADATA.GET_DDL`. Tracked in #95.

## Tables

Planned, not built. It splits hard by engine: sqlite, mysql/mariadb and
clickhouse hand back `CREATE TABLE` in one query, postgres and sql server have
to be hand assembled. The strategy table and phasing live on
[#90](https://github.com/TheNoeTrevino/dadbod-ui.nvim/issues/90).

The plumbing is ready. `drawer/actions.lua` dispatches with no type branches,
`Query:write_script` already takes `{ table, schema }`, and table nodes
already expand.
