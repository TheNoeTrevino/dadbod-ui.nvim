# Auto-pagination

Result buffers show one page at a time (`config.results.page_size`, default 200) and you step through with `[` and `]`. We append a paging clause to the
sql before it runs. We never wrap it in a subquery.

## Where the code lives

- [`lua/dadbod-ui/paginator.lua`](../lua/dadbod-ui/paginator.lua) has the
  guard and the clause building.
- The style is the `pagination` field on the adapter spec. No field means no
  pagination, the query just runs unmodified.
- [`lua/dadbod-ui/dbout/pagination.lua`](../lua/dadbod-ui/dbout/pagination.lua)
  handles the stepping and page state.

## The two styles

| Style          | Clause                           | Adapters                         |
| -------------- | -------------------------------- | -------------------------------- |
| `limit_offset` | `LIMIT <length> OFFSET <offset>` | PG, SQLite, ClickHouse, BigQuery |
| `limit_comma`  | `LIMIT <offset>, <length>`       | MySQL, MariaDB                   |

Offset is `(page - 1) * page_size`. Pages are 1 based.

## The guard

We only paginate a single plain SELECT. The guard rejects:

- anything that doesnt start with `SELECT`
- more than one statement (an inner `;`)
- any of these words: `limit`, `offset`, `fetch`, `top`, `into`, `update`,
  `procedure`. An existing paging clause would double page, the rest mean it
  isnt a plain select.

The guard is loose on purpose and fails safe. A column named `top_score` will
false positive, and the query just runs unpaginated. Nobody notices. Do NOT
copy these patterns into anything that refuses to run a query, that is what
the statement classifier is for (#101). The guard moves onto it when that
lands.

## Known gaps

SQL Server and Oracle have no `pagination` field on purpose. Both need
`OFFSET`/`FETCH`, a third style, and SQL Server requires an `ORDER BY` for it.
Tracked in #95.
