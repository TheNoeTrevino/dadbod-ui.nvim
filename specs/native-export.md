# Spec: Native CLI Result Export (CSV / JSON / Markdown / HTML / XML / SQL / TSV)

Status: **DONE — T1–T16 complete (v1)**
Owner: Noe Trevino
Branch: `feat/export-data-using-cli`
Reference UI: DBeaver "Data Transfer → Target format" picker.

---

## 0. How to execute this spec (contract for `/loop`)

This document is the source of truth. Each loop tick does exactly this:

1. Read the **Task Ledger** (§14). Pick the **first unchecked task** whose
   dependencies are all checked.
2. Implement it **test-first**: write/extend its spec file, then the module,
   until the named assertions pass.
3. Gate: `make test` is **fully green** and `make fmt-check` is **clean**.
4. Check the task's box in §14, append a one-line note under it if anything
   deviated from the spec, and **commit** with `feat(export): <task title>`
   (or `test(export):` / `docs(export):` as appropriate).
5. Stop the tick. Do **not** start the next task in the same tick unless the
   one just finished was trivial and fully verified.

Rules:
- **Pure modules first** (§9 modules 1–3): they have no Neovim/DB dependency and
  are fully unit-testable. Get them green before touching orchestration.
- Never weaken or delete an assertion to make the suite pass. If the spec is
  wrong, fix the spec text in the same commit and say so in the note.
- If a task is blocked on a real decision, stop and record it under
  **Open Questions** (§13) instead of guessing.
- Keep `dadbod-ui.bridge` the only engine boundary, but note: **export does NOT
  go through dadbod's `:DB`**. It runs the CLI directly via `vim.system`
  (the same mechanism `bridge.run_many` already uses), so export is independent
  of dadbod's async job and works even while a result is on screen.

---

## 1. Problem & goal

Today a query result is the database CLI's aligned text in a `.dbout` buffer.
Users want to export a result to common interchange formats, like DBeaver's
Data Transfer wizard. We keep `vim-dadbod` as the engine and implement export by
**re-running the query through the adapter's CLI in a machine-readable mode**,
then either passing that output straight through (when the CLI emits the target
format natively) or running a small pure-Lua formatter over a parsed canonical
intermediate.

**Goal:** export the current result buffer's query to CSV, JSON, Markdown, HTML,
XML, SQL (`INSERT`), and TSV — faithfully (NULLs preserved where the CLI allows),
via a picker that mirrors the DBeaver target-format list, plus a command and a
result-buffer mapping.

---

## 2. Non-goals (explicitly out of scope)

- **"Database" target** (table-to-table transfer between two connections) — that
  is DBeaver's DTPipe; a separate, much larger feature.
- **DbUnit / "Source code" targets** — niche; not planned.
- **XLSX** — requires writing an OOXML zip; deferred. Tracked as a stretch task
  (T17) but **not** part of the definition of done for this spec.
- Editable result grids, typed cell editing, transactions — all require dropping
  dadbod (see the project discussion); not in this spec.
- Export of arbitrary buffers — export targets a `.dbout` result buffer (it has
  the stored query + connection). Exporting an SQL buffer directly is a possible
  follow-up, not in scope here.

---

## 3. The native-CLI approach (core idea)

Two distinct uses of the CLI:

- **Canonical extractor** — always a native delimited mode. This is the faithful
  row source we parse into `ExportData` (§10):
  - postgres (`psql`): `--csv` (RFC-4180, with header)
  - mysql/mariadb: `--batch` (TSV; NULL as literal `\N`; tab/newline/backslash escaped)
  - sqlite3: `-csv -header`
- **Native target passthrough** — when the CLI can emit the requested target
  format directly, and `prefer_native` is on (default), write its stdout straight
  to the file with no re-formatting. Otherwise extract + Lua-format.

See **DECISION-001** (§12) for the precedence rule and the consistency trade-off.

---

## 4. Capability matrix (per adapter)

`extract` = canonical delimited mode (faithful rows). `native:<fmt>` = the CLI
flag that emits that target format directly (passthrough candidate). Absent =
produced by the Lua formatter from the canonical extract.

| Adapter         | extract (canonical)      | native csv | native json | native md | native html | native xml | native tsv |
|-----------------|--------------------------|:----------:|:-----------:|:---------:|:-----------:|:----------:|:----------:|
| postgres/psql   | `--csv`                  | `--csv`    | —           | —         | `-H`        | —          | —          |
| mysql/mariadb   | `--batch` (TSV, `\N`)    | —          | —           | —         | `--html`    | `--xml`    | — (R2)²   |
| sqlite3         | `-csv -header`           | `-csv`     | `-json`     | — (IT)³   | — (T16)¹  | —          | —          |
| sqlserver       | (unsupported v1)         | —          | —           | —         | —           | —          | —          |
| oracle/bigquery/clickhouse | (unsupported v1) | —    | —           | —         | —           | —          | —          |

¹ sqlite `-html` was dropped from native after T16 verification: it emits a bare
`<TR>` fragment (no `<table>`) and renders NULL as the literal `null`. sqlite HTML
therefore always uses the Lua formatter (proper `<table>`, NULL → empty).

² mysql `--batch` (TSV) was dropped from native after a second review: its raw
framing writes literal `\N` for NULL, inconsistent with postgres/sqlite TSV
(formatter, NULL → empty). TSV is now uniformly the Lua formatter across adapters.

³ sqlite `-markdown` was dropped from native after the export integration suite
(`integration/`) ran it against multiple sqlite3 versions: its numeric-column
alignment changed between releases (older builds left-justify, newer right-justify),
so the raw passthrough is not reproducible. Markdown is now uniformly the Lua
formatter. sqlite `-json`/`-csv` stay native (stable, and `-json` preserves real
NULL — the reason it is kept despite LIMITATION-001).

**Post-M16 hardening (second review):** (a) every export argv is rc-suppressed —
psql `--no-psqlrc`, sqlite `-init <nulldev>` — so a user's `~/.psqlrc` / `~/.sqliterc`
can't inject lines into the parsed output (mysql uses `--batch` + stdin and is left
as-is to preserve `~/.my.cnf` auth); (b) sqlite delivers the query on **stdin**, not
as a positional arg, so a query starting with `-` (e.g. a `-- comment` line) no longer
aborts; (c) the interactive flow **confirms before overwriting** an existing file.

Notes:
- **v1 supported adapters: postgres, mysql/mariadb, sqlite.** Others report
  "export not supported for <scheme>" until their matrix row is filled in
  (mirrors how `paginator.supports` gates schemes). Adding an adapter later is
  one matrix row + tests.
- Native HTML differs cosmetically per CLI; with `prefer_native=false` the Lua
  HTML formatter is used everywhere for consistent output (DECISION-001).
- The exact argv interaction with dadbod's generated command (flag position,
  stdin vs `-c`/`-e` query delivery) is **verified by the T2 spike** before the
  orchestrator is built.

---

## 5. Target formats & requirements

Every format consumes `ExportData` (§10). Each formatter is a pure function
`format(data, opts) -> string[]` (buffer-ready lines) or `-> string`. Fixtures
below are the **acceptance fixtures** — tests assert these exact outputs.

Shared fixture `ExportData`:
- columns: `{ "id", "name", "note" }`
- rows:
  - `{ "1", "Ann", NULL }`
  - `{ "2", "O'Brien", "has, comma" }`
  - `{ "3", "Zoë", "line\nbreak" }`

(`NULL` is the `ExportData.NULL` sentinel, §10.)

### 5.1 CSV  (port of `DataExporterCSV`)
Opts: `delimiter=','`, `header=true`, `quote='"'`, `null_string=''`,
`line_feed_escape=nil`. Quote a field iff it contains the delimiter, the quote
char, CR, or LF. Escape quotes by doubling. NULL renders as `null_string`.
Expected (default opts):
```
id,name,note
1,Ann,
2,O'Brien,"has, comma"
3,Zoë,"line
break"
```

### 5.2 TSV
CSV formatter with `delimiter='\t'` and (by default) no quoting — values with
tab/newline get the `line_feed_escape`/tab-escape treatment instead. Acceptance:
same rows, tab-separated, embedded newline replaced by `\n` literal when
`line_feed_escape='\\n'`.

### 5.3 JSON  (port of `DataExporterJSON`)
Opts: `wrap_table_name=true` (key = source/table name), `indent='\t'`,
`coerce_numbers=false`. Each row is an object keyed by column name. NULL → `null`
literal. With `coerce_numbers=false` every non-null value is a quoted string
(CSV extract carries no types — see LIMITATION-002). With `coerce_numbers=true`,
values matching `^-?%d+%.?%d*$` and `true|false` are emitted unquoted (heuristic).
Expected (`wrap_table_name=false`, `coerce_numbers=false`):
```json
[
	{
		"id" : "1",
		"name" : "Ann",
		"note" : null
	},
	{
		"id" : "2",
		"name" : "O'Brien",
		"note" : "has, comma"
	},
	{
		"id" : "3",
		"name" : "Zoë",
		"note" : "line\nbreak"
	}
]
```
String escaping: `"` `\` and control chars (`\n` `\t` `\r`) per JSON.

### 5.4 Markdown  (port of `DataExporterMarkdownTable`)
GitHub table. Header row, `---` separator row, one row per record. Cell content:
pipes escaped as `\|`, newlines replaced by `<br>`, NULL → empty. Expected:
```
| id | name | note |
| --- | --- | --- |
| 1 | Ann |  |
| 2 | O'Brien | has, comma |
| 3 | Zoë | line<br>break |
```

### 5.5 HTML  (port of `DataExporterHTML`)
A `<table>` with `<thead>`/`<tbody>`. HTML-escape `& < > "`. NULL → empty cell.
**OQ-2 resolved (T6):** cell newlines render as `<br>`. Minimal, no inline CSS.

### 5.6 XML  (port of `DataExporterXML`)
`<data>` root; each row `<row>`; **OQ-2 resolved (T6):** element-per-column
`<col name="...">value</col>`. XML-escape `& < > " '`. NULL → self-closing
`<col name="..." isNull="true"/>`.

### 5.7 SQL `INSERT`  (port of `DataExporterSQL`)
`INSERT INTO <table> (cols) VALUES (...);` per row (or multi-row `VALUES`).
Target table name from `b:dbui_table_name`, else prompt, else `exported_table`.
String values single-quoted with `'` doubled; NULL → bare `NULL`; numeric
literals unquoted only when `coerce_numbers=true`. Identifier quoting follows the
adapter's `quote` flag (§ existing `entry.quote`).

---

## 6. NULL & type fidelity (be honest about the CLI limits)

- **mysql `--batch`**: real NULL as `\N` → faithful. The extractor maps `\N`
  (unescaped, i.e. not `\\N`) to `ExportData.NULL`.
- **mysql/mariadb NULL is client-dependent (LIMITATION-003)**: the export
  integration suite showed Oracle's `mysql` client emits `\N` for NULL under
  `--batch`, but MariaDB's client emits the literal word `NULL`. The extractor maps
  **both** whole-field `\N` and `NULL` (data rows only) to `ExportData.NULL`, so a
  real string value of `\N`/`NULL` is indistinguishable from SQL NULL — same
  empty-vs-NULL ambiguity class as LIMITATION-001. The `--html`/`--xml` native
  passthrough is raw client bytes and also differs between clients; the integration
  goldens are recorded with (and CI pinned to) the MariaDB client.
- **sqlite `-csv`**: NULL renders as empty, indistinguishable from `''`
  (LIMITATION-001). When NULL fidelity matters for sqlite (JSON/SQL targets),
  the extractor MAY use `-json` instead and read real `null` — decide in T8,
  record the choice. Default: accept empty-as-NULL for sqlite CSV extract.
- **psql `--csv`**: NULL renders as empty (LIMITATION-001, same as sqlite). `\pset
  null` is ignored in CSV mode. Documented limitation; no silent fix.
- **Types (LIMITATION-002)**: the CSV/TSV extract is all strings. JSON/SQL
  numeric/boolean output is therefore opt-in via `coerce_numbers` (regex
  heuristic), off by default. DBeaver gets types from JDBC; we cannot from CSV.

Every limitation above is surfaced in `:help`/README, never hidden.

---

## 7. Where the data comes from (re-execution)

Export operates on a `.dbout` result buffer:
- Connection url: `b:db.db_url`.
- Query SQL: the stored input temp file via `bridge.dbout_input(<file>)`
  (already exists), read with `readfile`.
- If the buffer is paginated (`b:dbui_page`), **DECISION-003** applies: default
  export = the **full original query** (un-paginated, `state.original_sql`);
  an option/second mapping exports **only the current page** by re-applying
  `paginator.paginate(scheme, original_sql, page, page_size)`.

Export re-runs that SQL with the matrix's export args via `vim.system` and never
touches dadbod's `:DB`/job.

---

## 8. UX / entry points

- **Command** `:DBUIExportResult` — run from (or with the cursor in) a `.dbout`
  buffer. Opens the format picker.
- **Mapping** `mappings.results.export` (suggested default `<Leader>X`), wired in
  `dbout.setup_buffer` alongside `jump_foreign`/`yank_header`. Added to
  `config.mappings.results`, `config.mapping_order.results`, and the help window.
- **Picker flow** (`vim.ui.select`, injectable like `Query.select`):
  1. Select target format — list filtered to what the buffer's adapter supports
     (matrix §4). Labels mirror the DBeaver list: `CSV`, `JSON`, `Markdown`,
     `HTML`, `XML`, `SQL`, `TSV`.
  2. `vim.ui.input` for the output path (default:
     `<cwd>/<table-or-query>-<timestamp>.<ext>`).
  3. Run; on success notify `Exported N rows to <path>` (info), on failure notify
     the CLI stderr (error). Async — show no blocking UI; reuse the notification
     module.
- Pickers/inputs are **injectable** (constructor fields) so specs drive them
  without real UI, exactly like `query.lua`/`drawer.lua`.

---

## 9. Architecture & modules

Flat layout under `lua/dadbod-ui/` (the repo has no subdirs). Three **pure**
modules + one thin impure orchestrator. This mirrors how `paginator.lua` is a
self-contained module with its own per-scheme table rather than bloating
`schemas.lua`.

1. **`export_formats.lua`** (PURE) — the formatters. `M.csv/json/markdown/html/
   xml/sql/tsv(data, opts) -> string|string[]`. No Neovim API, no DB. Plus the
   shared `ExportData.NULL` sentinel and string-escape helpers. **Bulk of the
   work; fully TDD-able.**
2. **`export_extract.lua`** (PURE) — parse a CLI's canonical stdout into
   `ExportData`. `M.from_csv(text, opts)`, `M.from_tsv(text, opts)`, dispatcher
   `M.parse(scheme, text)`. RFC-4180 CSV parsing (quoted fields, embedded
   delimiters/newlines, doubled quotes) is the trickiest pure bit — prime TDD
   target.
3. **`export_adapters.lua`** (PURE data + small fns) — the capability matrix (§4),
   `M.supports(scheme)`, `M.formats_for(scheme) -> string[]`,
   `M.extract_args(scheme)`, `M.native_args(scheme, fmt) -> string[]|nil`, and
   `M.is_native(scheme, fmt, prefer_native) -> boolean`. Knows flags, not how to
   run them.
4. **`export.lua`** (IMPURE orchestrator) — ties it together: read query+url from
   the dbout buffer, build the `CommandSpec` (base argv via `bridge.command`,
   plus extract/native args, query via stdin-or-arg per adapter), run
   `vim.system`, then either passthrough-write or `extract` → `format` → write,
   then notify. Owns the picker entry points and the `:DBUIExportResult` command.

Cross-module data flows through `ExportData` (§10) only.

---

## 10. Data shapes

```lua
--- Canonical export intermediate. A faithful, string-typed view of a result set
--- parsed from a CLI's delimited output. NULL is the module sentinel, never nil
--- (Lua arrays must not hold nil holes).
---@class DadbodUI.ExportData
---@field columns string[]                 -- column names, in order
---@field rows table[]                     -- each row: array of (string | ExportData.NULL)
---@field source? string                   -- table/query name, for JSON wrap + SQL target

-- export_formats.NULL : a unique table sentinel. Cells compare `cell == NULL`.

---@class DadbodUI.ExportOpts
---@field format 'csv'|'json'|'markdown'|'html'|'xml'|'sql'|'tsv'
---@field path string                      -- output file
---@field page 'full'|'current'            -- default 'full' (DECISION-003)
---@field prefer_native boolean            -- default from config (DECISION-001)
---@field format_opts table                -- per-format options (§5)
```

---

## 11. Config additions

Add to `config.lua` `M.defaults`:
```lua
export = {
  prefer_native = true,          -- DECISION-001
  default_path = '',             -- '' => <cwd>; else a dir
  coerce_numbers = false,        -- LIMITATION-002 heuristic, off by default
  csv  = { delimiter = ',', header = true, quote = '"', null_string = '', line_feed_escape = '' },
  tsv  = { line_feed_escape = '\\n' },
  json = { wrap_table_name = true, indent = '\t' },
  -- markdown/html/xml/sql carry their decided defaults
},
```
Mapping additions:
- `M.defaults.mappings.results.export = { key = '<Leader>X', desc = 'Export result to a file' }`
- `M.mapping_order.results` gains `'export'`.
Type additions: `DadbodUI.ExportData`, `DadbodUI.ExportOpts`, and an
`export` field on `DadbodUI.Config` in `types.lua`.

---

## 12. Decisions log

- **DECISION-001 (native-first, toggleable):** the canonical extractor is always
  a native delimited mode. For the target format, if the adapter emits it
  natively and `prefer_native` (default true), pass stdout through unmodified;
  otherwise extract + Lua-format. `prefer_native=false` forces the Lua formatters
  everywhere for cross-adapter consistency. Honors "use the CLI's native modes"
  while guaranteeing universal coverage.
- **DECISION-002 (independent of dadbod's job):** export runs the CLI via
  `vim.system`, not `:DB`. Rationale: avoids dadbod's "query already running for
  this tab", lets export run alongside a visible result, and keeps the faithful
  delimited output instead of the aligned `.dbout` text.
- **DECISION-003 (full query by default):** a paginated result exports the full
  original query; current-page export is an explicit option.
- **DECISION-004 (v1 adapters):** postgres, mysql/mariadb, sqlite only. Others
  gated off via `export_adapters.supports`.

LIMITATION-001 (NULL≡empty for psql/sqlite CSV) and LIMITATION-002 (no types
from CSV → opt-in `coerce_numbers`) are documented, not worked around.

---

## 13. Open questions (resolve before the dependent task; don't guess)

- **OQ-1 (T2 spike):** exact export argv per adapter on top of dadbod's
  `bridge.command(url, callable)` — does `--csv -c <query>` (psql) / `--batch -e
  <query>` (mysql) / `-csv -header <query>` (sqlite) compose cleanly, and is the
  query delivered as an arg or stdin? Resolve empirically, record the argv in an
  appendix here, THEN build T9/T10.
- **OQ-2 (T6):** HTML newline handling (`<br>` vs raw) and XML cell shape
  (attribute `name=` vs element-per-column). Pick to match DBeaver output; record.
- **OQ-3 (T8):** does sqlite use `-csv` or `-json` as its canonical extractor
  (NULL fidelity vs simpler parsing)? Default `-csv`; revisit if SQL/JSON NULLs
  matter in testing.

---

## 14. Task Ledger

Order = dependency order. `[ ]` = todo, `[x]` = done. Each task lists files and
**acceptance** (the concrete gate). Global gate on every task: `make test` green
+ `make fmt-check` clean.

### Phase 0 — scaffolding & de-risking

- [x] **T1 — Land this spec.** Files: `specs/native-export.md`. Acceptance: file
  committed on the branch. (This commit.)
- [x] **T2 — Command-construction spike (OQ-1).** Deps: T1. Files: append an
  "Appendix A: verified argv" section to this spec. Acceptance: for sqlite +
  postgres (+ mysql if reachable), the exact `vim.system` argv that produces
  `--csv`/native output is recorded, with a one-paragraph note on stdin-vs-arg
  delivery. No production code required; this de-risks T9/T10. If no DB is
  reachable in the loop env, record the derived argv from dadbod's adapter
  source + a manual-verification checklist and mark T2 done with a `BLOCKED-ON-DB`
  note.

### Phase 1 — pure formatters & parsing (no Neovim/DB; strict TDD)

- [x] **T3 — CSV/TSV formatter.** Deps: T1. Files: `lua/dadbod-ui/export_formats.lua`,
  `tests/export_formats_spec.lua`. Acceptance: §5.1 and §5.2 fixtures match
  exactly, incl. quoting, doubled quotes, NULL→`null_string`, and TSV
  `line_feed_escape`.
- [x] **T4 — JSON formatter.** Deps: T3. Files: same module + spec. Acceptance:
  §5.3 fixture exact (wrapped and unwrapped), JSON escaping, `null` literal,
  `coerce_numbers` on/off.
- [x] **T5 — Markdown formatter.** Deps: T3. Acceptance: §5.4 fixture exact, pipe
  escaping, `<br>` newlines, NULL→empty.
- [x] **T6 — HTML + XML formatters (resolve OQ-2).** Deps: T3. Acceptance: header
  +rows render; `&<>"`(+`'` for XML) escaped; NULL handling per the recorded
  decision; chosen shapes documented in §5.5/§5.6.
- [x] **T7 — SQL `INSERT` formatter.** Deps: T3. Acceptance: one statement per
  row, `'`-doubling, `NULL` bare, identifier quoting honored, target-table
  fallback chain.
- [x] **T8 — Canonical extractor (resolve OQ-3).** Deps: T1. Files:
  `lua/dadbod-ui/export_extract.lua`, `tests/export_extract_spec.lua`. Acceptance:
  RFC-4180 CSV parse (quoted fields, embedded `,`/CR/LF, doubled quotes) and TSV
  parse with `\N`→NULL; round-trips the §5 fixture from a CSV string back to
  `ExportData`; header row consumed into `columns`.
- [x] **T9 — Adapter capability matrix.** Deps: T1, T2. Files:
  `lua/dadbod-ui/export_adapters.lua`, `tests/export_adapters_spec.lua`.
  Acceptance: `supports/formats_for/extract_args/native_args/is_native` match §4
  for postgres/mysql/mariadb/sqlite under raw+canonical scheme names; unsupported
  schemes return false/empty (mirror `paginator_spec` style).

### Phase 2 — orchestration (Neovim; bridge + vim.system stubbed in tests)

- [x] **T10 — Orchestrator core.** Deps: T3–T9. Files: `lua/dadbod-ui/export.lua`,
  `tests/export_spec.lua`. Acceptance (with `bridge`/`vim.system` injected/stubbed):
  reads query+url from a fake dbout buffer; native path writes CLI stdout
  verbatim; non-native path runs extract→format→write; success/error both
  notify; writes the expected file contents for a sqlite-csv (native) and a
  postgres→json (extract+format) case.
- [x] **T11 — Entry points + picker.** Deps: T10. Files: `export.lua`,
  `dbout.lua` (wire `export` handler in `setup_buffer`), `plugin/dadbod-ui.lua`
  (`:DBUIExportResult`). Acceptance: command opens the picker; picker is the
  injectable `select`; format list = `formats_for(scheme)`; path defaulting tested
  via injected input; mapping invokes the same handler.
  - Note: `:DBUIExportResult` + the dbout `export` handler are wired now; the
    `<Leader>X` keybinding activates with T12 (config `results.export` entry).
- [x] **T12 — Config + mappings + types.** Deps: T10. Files: `config.lua`,
  `types.lua`, `tests/config_spec.lua` (extend). Acceptance: `export` defaults
  present and overridable via deep-merge; `results.export` mapping + `mapping_order`
  entry present; help window lists it; type defs added.
- [x] **T13 — Pagination option (DECISION-003).** Deps: T10. Acceptance: default
  exports full `original_sql`; `page='current'` re-applies `paginator.paginate`;
  non-paginated buffers ignore the option. Covered in `export_spec`.
- [x] **T14 — Errors & edge cases.** Deps: T10–T13. Acceptance: unsupported
  adapter, unsupported format-for-adapter, empty result set, CLI non-zero exit
  (stderr surfaced), and unwritable path each produce a specific notification and
  no partial/corrupt file. Tests assert the messages.

### Phase 3 — docs & verification

- [x] **T15 — Docs.** Deps: T11–T14. Files: `README.md` (export section +
  limitations §6), help/`?` entry. Acceptance: documents formats, matrix,
  `prefer_native`, and both LIMITATIONs.
- [x] **T16 — End-to-end manual verification.** Deps: T15. Acceptance: with a real
  sqlite db in a scratch dir, export each format and eyeball; record results as a
  checklist in Appendix B. (Manual; loop records the checklist and any follow-ups.)

### Stretch (not in definition of done)

- [ ] **T17 — XLSX** (OOXML zip writer or shell-out). Deps: T10. Out of v1 scope.
- [ ] **T18 — More adapters** (sqlserver/oracle/bigquery/clickhouse rows). Deps: T9.

**Definition of done for this spec:** T1–T16 checked, `make test` green,
`make fmt-check` clean, README updated.

---

## 15. References

DBeaver exporters (read for logic, port to Lua — do not copy license-bearing code
verbatim; reimplement):
- `dbeaver/.../tools/transfer/stream/exporter/DataExporterCSV.java`
- `.../DataExporterJSON.java`
- `.../DataExporterMarkdownTable.java`
- `.../DataExporterHTML.java`
- `.../DataExporterXML.java`

In-repo patterns to follow:
- `lua/dadbod-ui/paginator.lua` — self-contained module + per-scheme table + its
  `paginator_spec.lua` (the model for `export_adapters` + its spec).
- `lua/dadbod-ui/schemas.lua` `command_spec` / `bridge.command` — how an adapter
  argv is built and a query delivered (stdin vs arg).
- `lua/dadbod-ui/query.lua` — injectable `input`/`select` backends for testable UI.
- `lua/dadbod-ui/dbout.lua` `setup_buffer` — where the results mapping is wired;
  `bridge.dbout_input` — how to recover the query that produced a result.

---

## Appendix A: verified argv (filled by T2)

`bridge.command(url, 'interactive')` (= `db#adapter#dispatch(resolve(url),'interactive')`)
returns these base argvs (verified headless against vim-dadbod):

- **sqlite**: `{ "sqlite3", "<dbfile>", "-column", "-header" }`
- **postgres**: `{ "psql", "-w", "--dbname", "<url>" }`
- **mysql**: `{ "mysql", "-h", "<host>", ... }` (derived; mysql CLI not installed in spike env)

Export command = base argv ++ export args, with the query delivered per adapter:

| Adapter  | extract args (csv path) | native args        | query delivery |
|----------|-------------------------|--------------------|----------------|
| sqlite   | `{'-csv','-header'}`    | json `{'-json'}`, md `{'-markdown'}`, html `{'-html'}` | **appended as last arg** |
| postgres | `{'--csv','-c'}`        | html `{'-H','-c'}` | **appended after `-c`** |
| mysql    | `{'--batch'}`           | xml `{'--xml'}`, html `{'--html'}` | **stdin** (`requires_stdin`) |

Verified empirically:
- sqlite appends flags **after** dadbod's `-column -header`; a later `-csv`/`-json`
  **overrides** them, and the trailing positional is taken as the SQL. Confirmed:
  `sqlite3 <db> -column -header -csv "SELECT * FROM t"` emits CSV;
  `... -json ...` emits a JSON array with real `null` and real numbers.
- psql accepts `psql -w --dbname <url> --csv -c "<query>"` (arg-level OK; only the
  connection failed against a fake host). NULL renders empty in `--csv`
  (LIMITATION-001 confirmed). psql HTML flag is `-H`.
- mysql delivery mirrors the introspection adapter (`requires_stdin = true`).
  NULL is `\N` under `--batch` (per mysql docs; not run here — `BLOCKED-ON-DB`
  for the live run, derivation recorded).

Implication for `export_adapters` (T9): model each adapter as
`{ callable, stdin = bool, args = function(fmt) -> string[] }` where the postgres
`args` list ends in `-c` (query appended after) and sqlite/postgres append the
query while mysql feeds it on stdin.

## Appendix B: manual verification checklist (filled by T16)

End-to-end against a real `sqlite3` (`id INTEGER, name TEXT, note TEXT`; rows
`(1,'Ann',NULL)`, `(2,'O''Brien','has, comma')`, `(3,'Zoe','line1')`), driving the
unstubbed `export.export` (real bridge + `vim.system` + writefile) for every format.

| Format | Path | Result |
|--------|------|--------|
| CSV | native `-csv` | ✅ RFC-4180, `O'Brien`/`has, comma` quoted, NULL → empty |
| JSON | native `-json` | ✅ real `null`, real numbers (`"id":1` unquoted) |
| Markdown | native `-markdown` | ✅ padded GitHub table, NULL → empty |
| HTML | ~~native `-html`~~ → Lua | ✅ after fix: proper `<table><thead><tbody>`, NULL → empty |
| XML | extract + Lua | ✅ `<col name="note"></col>` (empty, per LIMITATION-001) |
| SQL | extract + Lua | ✅ one `INSERT`/row, `''` doubled; NULL → `''` (LIMITATION-001) |
| TSV | extract + Lua | ✅ tab-separated, NULL → empty |

**Findings & actions:**
1. **sqlite `-html` is a broken default** — native sqlite emits a bare `<TR>`
   fragment (no `<table>`) and renders NULL as the literal text `null`. **Action
   taken:** dropped `html` from sqlite's native map (export_adapters.lua); sqlite
   HTML now uses the Lua formatter. Matrix footnote ¹ + test updated. postgres `-H`
   / mysql `--html` emit full `<table>`s and stay native.
2. **LIMITATION-001 confirmed live** — on sqlite, a real NULL survives only through
   the **native JSON** path (`-json` → real `null`). Every CSV-extract-based path
   (csv/tsv/xml/sql) renders it as empty, because `sqlite3 -csv` cannot distinguish
   NULL from `''`. Documented; not a bug.

No further code changes needed; all 7 formats produce valid, correct files.
