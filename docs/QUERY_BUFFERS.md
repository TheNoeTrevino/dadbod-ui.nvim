# Query buffers

The buffers you write SQL in. Every one is a real file on disk with a real
`.sql` extension (or whatever the adapter's extension is), so formatters,
linters and LSPs treat it like a normal SQL file. "Scratch" just means the
file lives under the tmp location instead of the save location.

## Where the code lives

- [`lua/dadbod-ui/query.lua`](../lua/dadbod-ui/query.lua) - the Query
  controller. Open, contract, execute, bind params, save, quit sweep.
- [`lua/dadbod-ui/bridge.lua`](../lua/dadbod-ui/bridge.lua) - the only module
  allowed to talk to vim-dadbod. User queries go through `:DB` here.
- [`lua/dadbod-ui/bind_params.lua`](../lua/dadbod-ui/bind_params.lua) - pure
  detection, quoting and substitution.

## The b:dbui_* contract

Every query buffer carries buffer-local vars, written in exactly one place
(`Query.write_contract`):

- `b:dbui_db_key_name` - the connection key. This is THE predicate for "is
  this a dbui query buffer".
- `b:db` - dadbod's live connection handle, what `%DB` runs against.
- `b:dbui_table_name` / `b:dbui_schema_name` - template context for helpers,
  also seeds export filenames.
- `b:dbui_bind_params` - answered bind parameter values.

These names are frozen (see constants.lua). Renaming any of them breaks user
configs and other plugins.

## Naming and ownership

`generate_buffer_name` puts the file in `entry.tmp_path`, which is
`<tmp_query_location>/<group-qualified name>`. The folder IS the ownership
record: on startup, state restores buffers by listing that folder, and
adopting a stray buffer resolves its connection by matching its directory.
If `tmp_query_location` isnt set, scratch files go to the session temp dir
and nothing persists.

## Execution

Run paths: the execute keymap (normal runs the buffer, visual runs the
selection), `execute_on_save`, and `api.buf.execute`.

1. Get the SQL. Visual selections are read with `getregion`, never `gvy` and
   never the `'<`/`'>` marks, because marks arent committed while youre still
   in visual mode and the old approaches raised E20/E475.
2. Detect bind parameters. If there are any, prompt (details below) and
   substitute.
3. Try to paginate (see AUTO_PAGINATION.md). Paginated queries stash their
   page state in dbout before running.
4. Dispatch. A whole-buffer run with no substitution, no transform and no
   pagination takes the `%DB` fast path. Everything else is written to a
   tempfile and run as `DB <url> < <file>`, which sidesteps all Ex command
   escaping.
5. dadbod runs the query as an async job, writes a `.dbout` file and fires
   autocmds. The result buffer side picks it up from there (see
   RESULT_BUFFERS.md).

Right before dispatch the query controller arms an "origin" (bufnr + line)
so the result side knows where to put the ghost timing text. A failed
dispatch must disarm it or the stale context leaks into the next unrelated
run.

`transform` (on `api.buf.execute`) is the one sanctioned way to mutate SQL on
the way out. The `on_execute_query` hook is observer only, its return value
is ignored. Substitution happens before the transform so it sees runnable
SQL.

## Bind parameters

Placeholders match `config.query.bind_param_pattern` (default `:\w+`).
Detection runs a small lexer over the whole statement first, masking
strings, quoted identifiers, dollar quotes and comments, so a `:name` inside
a string literal is never a parameter. A `::text` cast isnt one either.

Values you answer get stored in `b:dbui_bind_params` and reused. An empty
value leaves the placeholder raw in the SQL, thats the escape hatch.
`<Leader>E` edits stored values before or between runs. The
`resolve_bind_params` config hook can answer names programmatically, anything
it doesnt answer falls back to a prompt.

## Quit behavior

`bufhidden=hide` keeps every scratch buffer loaded, which is what lets one
query window swap between buffers, but it also means quitting Vim used to
prompt E37 once per modified scratch buffer (issue #74). A global `QuitPre`
autocmd sweeps them: `save_on_exit = 'auto'` writes them (only when the tmp
location persists), `'discard'` clears modified, `'ask'` leaves Vims prompt
alone. Saved queries are deliberately not swept, you named those on purpose.
The sweep writes with `noautocmd` so `execute_on_save` doesnt run every
scratch query on the way out.

## Gotchas

- Its `QuitPre`, not `VimLeavePre`. Vim raises the save prompt while
  deciding to quit, before `VimLeavePre` ever fires. And the autocmd is
  global, not buffer-local, because the buffers being prompted about are
  precisely the hidden ones.
- Never `fnameescape` the url spliced into `:DB`. Escaping `%` mangles
  percent-encoded credentials. And a newline in the SQL would terminate the
  Ex command, which is why multi-line SQL always goes through the tempfile.
- Async prompts (bind params, pickers) capture `bufnr` and `entry` before
  prompting. Focus can move and buffers can die before the callback runs,
  and execution targets the captured entry, not whatever is current.
- The bridge uses `silent`, not `silent!`, so a failed dispatch still raises
  into the callers pcall.
- `setup_buffer` sets the filetype under pcall. A throwing third-party
  FileType autocmd must not abort opening the buffer.
- Buffers opened by Script As are filled raw: no placeholder substitution
  and no auto-execute, because scripted DDL (a DROP) must never run just
  from being opened.
