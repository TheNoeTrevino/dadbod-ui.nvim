# Result buffers (.dbout)

The read-only buffers query results land in. dadbod itself opens them: it
creates an empty preview buffer, fires `*DBExecutePre`, runs the query async,
reloads the file with rows, fires `*DBExecutePost`. Everything we do hangs
off those two events.

## Where the code lives

- [`lua/dadbod-ui/dbout/init.lua`](../lua/dadbod-ui/dbout/init.lua) - the
  coordinator. Autocmd wiring, the pending context handoff, spinner, and it
  re-exports every submodule surface (the foldexpr string references
  `require'dadbod-ui.dbout'`, so things must stay reachable from here).
- [`lua/dadbod-ui/dbout/cells.lua`](../lua/dadbod-ui/dbout/cells.lua) -
  folds, cell/header navigation, FK jump, layout toggle.
- [`lua/dadbod-ui/dbout/winbar.lua`](../lua/dadbod-ui/dbout/winbar.lua) -
  the winbar (query time, page info, export progress) and ghost text.
- [`lua/dadbod-ui/dbout/pagination.lua`](../lua/dadbod-ui/dbout/pagination.lua) -
  `[` / `]` stepping (see AUTO_PAGINATION.md for the clause building).
- [`lua/dadbod-ui/dbout/ctx.lua`](../lua/dadbod-ui/dbout/ctx.lua) - two
  fields of shared state, exists only to break the require cycle between
  init and the submodules.

## The pending context handoff

The query side knows things the result side needs: which buffer/line the
query came from (for ghost text) and the page state (for `[` / `]`). It cant
put them on the result buffer because that buffer doesnt exist yet. So:

1. Right before dispatch, query.lua arms a pending context (`arm_origin`,
   `set_pending`).
2. `DBExecutePre` fires synchronously inside the `:DB` call and "claims" the
   pending context into a map keyed by output file.
3. `DBExecutePost` pops it by file and tags the buffer (`b:dbui_page` etc).

The file keying is what makes concurrent queries finishing out of order land
on the right buffers. The synchronous claim is what makes it race-free, no
other run can interleave between arm and claim. Dont move either.

## How the output is parsed

We parse dadbod's aligned text output, there is no structured result set.
Two layers:

- Generic: the fold expr and the winbar row counter recognize dash rules
  (`----`, `+---+`) and the three footer phrasings (`(N rows)`,
  `N rows in set`, `(N rows affected)`). No footer means count by lines, and
  if neither works the row count is just omitted, never guessed.
- Per adapter: cell navigation needs to find the header underline. Thats
  `cell_line_pattern` (a vim regex) and `cell_line_number` on the adapter
  spec. FK jump needs `foreign_key_query`, `select_foreign_key_query` and
  `parse_results` on top of that.

Cell spans are computed on the separator line, which is pure ascii so byte
columns equal display columns there. The data and header lines are NOT, psql
and mysql pad by display width, so the span gets remapped char by char onto
byte offsets (`display_span_to_byte_span`). Skip that and cell nav drifts
after the first wide character.

## FK jump, in short

Find the cell under the cursor, take its header slice as the column name and
its value, substitute the column into the adapter's `foreign_key_query`, run
that introspection query non blocking, and if it returns a
(table, column, schema) row, format `select_foreign_key_query` with it and
execute. The result is just another .dbout through the normal flow. A
re-entrancy flag stops a second jump mid flight.

## Winbar and spinner

While running: a static "running" winbar segment plus an animated spinner
written into the buffer itself (the buffer is nomodifiable, we flip the
option; dadbod's reload discards those edits). Its a winbar and not a
virt_lines extmark because neovim cant draw virtual lines above line 1.

After: query time + row count in the winbar, and the same summary as ghost
text on the line you executed from. The ghost text clears on any edit.

All winbar text has `%` doubled so engine output cant inject statusline
codes.

## Gotchas

- `b:db` on a result buffer is a table dadbod fills in (`db_url`, `input`,
  `runtime`, `exit_status`). `runtime` and `exit_status` are strings, always
  tonumber them. Reading `b:db.input` goes through `bridge.dbout_input`, the
  table shape is a dadbod internal.
- dadbod's "DB: Query finished" echo happens async, after our hook returns,
  so `:silent` cant reach it. We schedule an `echo ''` next tick. Noice
  style message UIs still capture it and need their own filter.
- The layout toggle (`\x` / `\G`) swaps `db.input` to a tempfile with the
  flag appended, reloads, then restores `db.input` even if the reload
  failed. Skip the restore and every retry appends the flag again. Also
  `vim.b.db` must be reassigned as a whole table, field writes arent seen.
- The FK `{col_name}` substitution uses a gsub function replacement so a `%`
  in a column name cant act as a capture reference.
