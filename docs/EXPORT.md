# Export

Writing a result buffer to a file (csv, tsv, json, markdown, html, xml, sql).
Two ways to produce the bytes:

1. Lua formatters. We run the query in a plain machine readable mode, parse
   the output into headers + rows, and a Lua function builds the csv/json/etc
   text from those rows. One function per format, in `export/formats.lua`.
   Thats a "Lua formatter". Since we build the format ourselves, this works
   for every adapter, which is why every adapter can export every format.
2. Native CLI passthrough. Some CLIs can emit the format themselves
   (`psql --csv`). When that exists and `results.export.prefer_native` is on
   (default), we skip the parsing and write the CLI's own output straight
   through. Its an optimization, not a requirement. Missing native support
   just means the Lua formatter does the work.

## Where the code lives

- [`lua/dadbod-ui/export/init.lua`](../lua/dadbod-ui/export/init.lua) orchestrates.
  Reads the query + connection off the `.dbout` buffer, re-runs it through the
  adapter CLI with `vim.system`, writes the file. It does NOT go through
  dadbod's `:DB` job, so it never collides with a running query. The
  collaborators are injectable through `deps` so tests dont need a database.
- [`lua/dadbod-ui/export/formats.lua`](../lua/dadbod-ui/export/formats.lua) -
  the pure formatters.
- [`lua/dadbod-ui/export/extract.lua`](../lua/dadbod-ui/export/extract.lua) -
  parses the CLI's delimited output for the formatters.
- [`lua/dadbod-ui/export/adapters.lua`](../lua/dadbod-ui/export/adapters.lua) -
  reads the `export` field off the adapter spec:
  - `stdin` - send the sql on stdin instead of argv
  - `extract` - CLI args that produce the delimited output
  - `native.<fmt>` - CLI args when the CLI emits `<fmt>` directly
- [`specs/native-export.md`](../specs/native-export.md) has the design
  decisions (DECISION-001 prefer_native, DECISION-002 vim.system).

## Native formats today

| Adapter | Native    |
| ------- | --------- |
| PG      | csv, html |
| MySQL   | html, xml |
| MariaDB | html, xml |
| SQLite  | csv, json |

Everything else goes through the Lua formatters.

## Gotchas

- sqlite `-markdown` and `-html` are NOT native on purpose. Markdown alignment
  changed between sqlite3 releases so the output isnt reproducible, and its
  html is a bare `<TR>` fragment that renders NULL as the text `null`. The Lua
  formatters are deterministic. Both verified in the integration suite.
- sqlite gets `-init <nulldev>` so your `~/.sqliterc` cant inject `.nullvalue`
  into output we parse strictly, and the sql goes over stdin because a
  positional string starting with `-` (a `-- comment`) reads as an unknown
  option.
- `make test-integration` compares export output to committed goldens against
  real databases in docker. A golden change is a deliberate output change,
  review the diff before committing.
