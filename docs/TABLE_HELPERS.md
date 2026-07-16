# Table helpers

The queries under an expanded table in the drawer (`List`, `Columns`,
`Indexes`, ...). Each one is a SQL template with placeholders like `{table}`
and `{schema}`.

## Where the code lives

- The SQL templates are the `table_helpers` field on each adapter spec in
  [`lua/dadbod-ui/adapters/`](../lua/dadbod-ui/adapters/). Usually a plain
  table. Its a function when a helper needs config (sqlite builds `List` from
  `config.query.default_query`).
- [`lua/dadbod-ui/table_helpers.lua`](../lua/dadbod-ui/table_helpers.lua) does
  the merging and ordering. No SQL in there.

## How it resolves

User overrides from `config.table_helpers` are laid over the adapter defaults.
An override keyed by the exact scheme beats one keyed by an alias. Setting a
helper to `''` removes it. If everything gets removed we fall back to a blank
`List` so the table still renders something.

Display order comes from `config.table_helpers_order`. Named helpers first, in
that order, everything else after alphabetically. Names the adapter doesnt
have are skipped.

## Per adapter

| Adapter    | Count | Helpers                                                                                 |
| ---------- | ----- | --------------------------------------------------------------------------------------- |
| MSSQL      | 8     | List, Columns, Indexes, Primary Keys, Foreign Keys, References, Constraints, Describe   |
| PG         | 6     | List, Columns, Indexes, Primary Keys, Foreign Keys, References                          |
| Oracle     | 6     | List, Columns, Indexes, Primary Keys, Foreign Keys, References                          |
| MySQL      | 5     | List, Columns, Indexes, Primary Keys, Foreign Keys                                      |
| MariaDB    | 5     | List, Columns, Indexes, Primary Keys, Foreign Keys                                      |
| SQLite     | 5     | List, Columns, Indexes, Primary Keys, Foreign Keys (all via `pragma_*` table functions) |
| ClickHouse | 2     | List, Columns                                                                           |
| BigQuery   | 2     | List, Columns                                                                           |
| Mongo      | 1     | List                                                                                    |

## Gotchas

- `Constraints` and `Describe` only exist on MSSQL right now.
- Mongo has no `Columns` since documents dont have them.
- Adding a helper is one entry on the adapter spec. Everything else picks it
  up automatically.
