# Adapters

One spec file per database in
[`lua/dadbod-ui/adapters/`](../lua/dadbod-ui/adapters/). A spec is a plain
table describing what the plugin can do for that engine. Every capability
module (schemas, table_helpers, explain, paginator, export) looks its data up
off the spec, so adding a capability to an adapter is adding a field, not
writing code paths.

## The spec shape

Only `name` is required, and it doubles as the url scheme. Everything else is
optional, and an absent field just means that feature is off for the adapter.
Full annotations are in [`types.lua`](../lua/dadbod-ui/types.lua)
(`DadbodUI.Adapter` and `DadbodUI.SchemaAdapter`).

| Field                                                                      | What lights up                                                       |
| -------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `name`, `aliases`                                                          | connection works, drawer lists tables via dadbod                     |
| `table_helpers`                                                            | helper leaves under each table                                       |
| `schema()` with `schemes_query` + `schemes_tables_query` + `parse_results` | schema browsing in the drawer                                        |
| `schema().procedures_query` (+ `routine_definition`)                       | the routines node                                                    |
| `schema().routine_scripts`                                                 | the routine Script As submenu (see SCRIPT_AS_DDL.md)                 |
| `schema().table_scripts`                                                   | the table Script As submenu (see SCRIPT_AS_DDL.md)                   |
| `schema().foreign_key_query` + `select_foreign_key_query` + cell fields    | dbout cell nav and FK jump                                           |
| `schema().layout_flag`                                                     | the expanded layout toggle (`\x`, `\G`)                              |
| `explain.plain` / `.analyze`                                               | EXPLAIN / EXPLAIN ANALYZE                                            |
| `explain.json` / `.json_analyze` + `.json_args` + `.parser`                | the EXPLAIN plan tree (see EXPLAIN_TREE.md)                          |
| `pagination`                                                               | `[` / `]` result paging                                              |
| `export`                                                                   | export, all formats (native ones per `export.native`, see EXPORT.md) |

`schema` is a function taking config (some adapters tune SQL off config, like
`use_postgres_views`). `table_helpers` can be a table or a function, sqlite
uses the function form so `List` tracks `config.query.default_query`.

The smallest real spec is mongodb: a name and one table helper. A new adapter
can start that small and grow field by field.

## Registration and resolution

`adapters/init.lua` keeps two maps: by scheme (canonical + aliases) and by
name. `api.register_adapter` replaces wholesale, it never merges, so a user
extending a built-in has to copy it first. And registration has to happen
before the connection list is built, because entries snapshot their adapter
metadata (`schema_support`, `quote`, `filetype`, ...) at build time. A late
registration silently misses existing entries.

mariadb is a separate adapter, not a mysql alias, on purpose: user
`table_helpers.mariadb` overrides have to stay scoped to mariadb connections.
It shallow-copies the mysql spec and only changes the analyze template.

## How introspection consumes a spec

`schemas/init.lua` builds a CLI command from the spec (`command_spec`),
runs it through `bridge.run_many` (our own `vim.system` processes, dadbod
only builds the argv), and `result_lines` converts the output to exactly the
framing dadbod's `db#systemlist` would produce. Adapters then parse with the
toolkit in `schemas/parse.lua`, usually `results_parser(lines, delimiter,
min_len)`: split each row on a vim regex delimiter and keep only rows with
exactly `min_len` fields. That width filter is also the header/footer
discard, which is why the queries and slicing rules in the specs "must not
be paraphrased", the framing is calibrated per CLI.

## Gotchas

- `result_lines` drops exactly ONE trailing blank line. sqlserver's fixed
  tail slice (`vslice(results, 0, -3)`) is calibrated to that. Change the
  framing and the tail cuts silently shift.
- The `args` on a routine script action REPLACES the adapter's args, it
  doesnt append. sqlserver's `definition_args` restates the trailing `-Q`
  for that reason, and has to stay in sync with any flag added to the
  adapter args.
- rc-file defenses are deliberate: postgres passes `--no-psqlrc` so a users
  `\timing` cant pollute parsed output, sqlite passes `-init <nulldev>` and
  sends sql over stdin. mysql deliberately does NOT pass `--no-defaults`
  because that would drop `~/.my.cnf` credentials.
- mysql has both `procedures_query` (server wide) and
  `tables_procedures_query` (scoped to the connected db). The scoped one
  exists so a url with a database in its path doesnt list every routine on
  the server under that one db.
- sqlite's FK query returns the literal `'main'` as the schema so the
  postgres style `"schema"."table"` select template works unchanged.
- sqlserver's plain routine-definition open path runs through dadbod's own
  argv, where `definition_args` cant apply, so its truncated at 256 chars.
  Script As is the full fidelity path.
