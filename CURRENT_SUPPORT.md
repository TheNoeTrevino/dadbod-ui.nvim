# Current support

This is just a way to keep track of the supported feature per adapter, so we dont have to hunt through files.

If the plugin DOES support something, and this doc says it does not, then this doc is obviously wrong and needs updating.

## Legend

| Symbol | Meaning                                          |
| ------ | ------------------------------------------------ |
| ✅     | Supported today                                  |
| ⬜     | Not yet - PRs welcome :)                         |
| ❌     | The engine has no such concept; nothing to build |

## Support matrix

| Feature                 |    PG     |   MySQL   |  MariaDB  |  SQLite   | MSSQL | Oracle | ClickHouse | BigQuery | Mongo | DuckDB | Snowflake | Presto | Impala | Redis | OSQuery |
| ----------------------- | :-------: | :-------: | :-------: | :-------: | :---: | :----: | :--------: | :------: | :---: | :----: | :-------: | :----: | :----: | :---: | :-----: |
| **Browsing**            |           |           |           |           |       |        |            |          |       |        |           |        |        |       |         |
| Connect + introspect    |    ✅     |    ✅     |    ✅     |    ✅     |  ✅   |   ✅   |     ✅     |    ✅    |  ✅   |   ⬜   |    ⬜     |   ⬜   |   ⬜   |  ⬜   |   ⬜    |
| Schema tree             |    ✅     |    ✅     |    ✅     |    ❌     |  ✅   |   ✅   |     ✅     |    ✅    |  ⬜   |   ⬜   |    ⬜     |   ⬜   |   ⬜   |  ⬜   |   ⬜    |
| Table listing           |    ✅     |    ✅     |    ✅     |    ✅     |  ✅   |   ✅   |     ✅     |    ✅    |  ✅   |   ⬜   |    ⬜     |   ⬜   |   ⬜   |  ⬜   |   ⬜    |
| Stored routines listed  |    ✅     |    ✅     |    ✅     |    ❌     |  ✅   |   ✅   |     ⬜     |    ⬜    |  ❌   |   ❌   |    ⬜     |   ⬜   |   ⬜   |  ⬜   |   ⬜    |
| Routine definition      |    ✅     |    ✅     |    ✅     |    ❌     |  ✅   |   ✅   |     ⬜     |    ⬜    |  ❌   |   ❌   |    ⬜     |   ⬜   |   ⬜   |  ⬜   |   ⬜    |
| **DDL Scripting**       |           |           |           |           |       |        |            |          |       |        |           |        |        |       |         |
| Script As - routines    |   ✅ 4    |    ⬜     |    ⬜     |    ❌     | ✅ 6  |   ⬜   |     ⬜     |    ⬜    |  ❌   |   ❌   |    ⬜     |   ⬜   |   ⬜   |  ⬜   |   ⬜    |
| Script As - tables      |    ⬜     |    ⬜     |    ⬜     |    ⬜     |  ⬜   |   ⬜   |     ⬜     |    ⬜    |  ❌   |   ⬜   |    ⬜     |   ⬜   |   ⬜   |  ⬜   |   ⬜    |
| **Query buffers**       |           |           |           |           |       |        |            |          |       |        |           |        |        |       |         |
| Table helpers           |   ✅ 6    |   ✅ 5    |   ✅ 5    |   ✅ 5    | ✅ 8  |  ✅ 6  |    ✅ 2    |   ✅ 2   | ✅ 1  |   ⬜   |    ⬜     |   ⬜   |   ⬜   |  ⬜   |   ⬜    |
| EXPLAIN                 |    ✅     |    ✅     |    ✅     |    ✅     |  ⬜   |   ✅   |     ✅     |    ⬜    |  ⬜   |   ⬜   |    ⬜     |   ⬜   |   ⬜   |  ⬜   |   ⬜    |
| EXPLAIN ANALYZE         |    ✅     |    ✅     |    ✅     |    ⬜     |  ⬜   |   ⬜   |     ⬜     |    ⬜    |  ⬜   |   ⬜   |    ⬜     |   ⬜   |   ⬜   |  ⬜   |   ⬜    |
| EXPLAIN plan tree       |    ✅     |    ✅     |    ✅     |    ❌     |  ❌   |   ❌   |     ⬜     |    ❌    |  ❌   |   ⬜   |    ⬜     |   ⬜   |   ⬜   |  ⬜   |   ⬜    |
| **Results (`.dbout`)**  |           |           |           |           |       |        |            |          |       |        |           |        |        |       |         |
| Auto-pagination         |    ✅     |    ✅     |    ✅     |    ✅     |  ⬜   |   ⬜   |     ✅     |    ✅    |  ⬜   |   ⬜   |    ⬜     |   ⬜   |   ⬜   |  ⬜   |   ⬜    |
| Foreign-key jump        |    ✅     |    ✅     |    ✅     |    ✅     |  ✅   |   ✅   |     ⬜     |    ⬜    |  ⬜   |   ⬜   |    ⬜     |   ⬜   |   ⬜   |  ⬜   |   ⬜    |
| Cell / header nav       |    ✅     |    ✅     |    ✅     |    ✅     |  ✅   |   ✅   |     ✅     |    ⬜    |  ⬜   |   ⬜   |    ⬜     |   ⬜   |   ⬜   |  ⬜   |   ⬜    |
| Vertical layout flag    |    ✅     |    ✅     |    ✅     |    ⬜     |  ⬜   |   ⬜   |     ⬜     |    ✅    |  ⬜   |   ⬜   |    ⬜     |   ⬜   |   ⬜   |  ⬜   |   ⬜    |
| **Export**              |           |           |           |           |       |        |            |          |       |        |           |        |        |       |         |
| Export (Lua formatters) |    ✅     |    ✅     |    ✅     |    ✅     |  ✅   |   ✅   |     ✅     |    ✅    |  ✅   |   ⬜   |    ⬜     |   ⬜   |   ⬜   |  ⬜   |   ⬜    |
| Native CLI export       | csv, html | html, xml | html, xml | csv, json |  ⬜   |   ⬜   |     ⬜     |    ⬜    |  ⬜   |   ⬜   |    ⬜     |   ⬜   |   ⬜   |  ⬜   |   ⬜    |

Counts (`✅ 6`) are how many actions/helpers that adapter defines today.

Columns exist for every database vim-dadbod can connect to, so a fully ⬜
column means "dadbod connects, we add nothing yet". Three dadbod adapters are
deliberately not columns: `jq` and `file` are not databases, and `dbext` is a
compatibility shim for another plugin's connection format.

### Per-feature detail

Each feature has a deep dive in [`./docs/`](docs/) - what it is, where the
source of truth lives, per-adapter facts and gotchas:

- [Table helpers](docs/TABLE_HELPERS.md)
- [Auto-pagination](docs/AUTO_PAGINATION.md)
- [Script As / DDL scripting](docs/SCRIPT_AS_DDL.md)
- [Export](docs/EXPORT.md) - including why a ⬜ in "Native CLI export" still
  exports fine (the Lua formatters cover every adapter; native is an
  optimization)

## Notes on accuracy

A few cells above are judgement calls rather than facts read off a spec, and are
flagged here rather than quietly guessed:

- ClickHouse has user-defined functions but not stored procedures in the
  PG/MSSQL sense; "routines listed" is marked ⬜, but it may turn out to be
  partly ❌ - there may be less there to build than the row implies.
- BigQuery's query-plan story (dry-run / job statistics) does not map cleanly onto
  an `EXPLAIN {sql}` template, so that ⬜ may not be reachable in the current
  `explain` shape.
- DuckDB's routine rows are ❌ because it has macros, not stored procedures in
  the PG/MSSQL sense (see #102). The rest of its column is ⬜ pending the
  adapter.
- The Snowflake / Presto / Impala / Redis / OSQuery columns are unresearched:
  every cell is ⬜ because nobody has checked yet, not because everything is
  buildable. Several will resolve to ❌ once someone looks - Redis especially,
  which has no tables, schemas or SQL at all. Whoever writes one of these
  adapters should correct its column in the same PR.
