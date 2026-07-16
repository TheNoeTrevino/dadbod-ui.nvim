# Architecture

The 10,000 foot view. Read this first, then the per-subsystem docs:
[ADAPTERS](ADAPTERS.md), [DRAWER](DRAWER.md), [QUERY_BUFFERS](QUERY_BUFFERS.md),
[RESULT_BUFFERS](RESULT_BUFFERS.md), [EXPORT](EXPORT.md),
[AUTO_PAGINATION](AUTO_PAGINATION.md), [TABLE_HELPERS](TABLE_HELPERS.md),
[SCRIPT_AS_DDL](SCRIPT_AS_DDL.md).

## Entry points

There are no user commands and no global mappings anywhere. `plugin/` is a
14 line boot guard (nvim >= 0.12 check), nothing more. Everything is driven
from lua:

- `require('dadbod-ui').setup(opts)` - optional. Resolves config and freezes
  it read only, drops the cached state and drawer. Nothing is built at setup
  time.
- `require('dadbod-ui.api')` - the stable scripting facade. Namespaced the
  `vim.lsp.buf` way: `api.*` works anywhere and addresses connections by
  name, `api.buf.*` acts on the current query buffer, `api.dbout.*` on the
  current result buffer.
- keymaps inside our own buffers (drawer, query, dbout), bound buffer-local
  by `mappings.apply`.
- `autoload/db_ui.vim` - two vimscript shims for third party plugins
  (vim-dadbod-completion). Thats the whole vimscript surface.

Everything is lazy. The drawer, the state instance and the controllers are
all built on first use, so requiring the plugin at startup costs near
nothing.

## The dependency graph

The rule that keeps the graph acyclic: `state` is the sink. It never
requires drawer, query or dbout. Controllers that need to trigger a redraw
(introspect, connections_controller) take an injected `render` callback
instead of requiring the drawer. The one acknowledged cycle is the picker
(api -> picker -> picker.utils -> api), which is why `api.pick` requires
picker inline.

```
                    api (facade, no logic)
                     |
   drawer ---- query ---- dbout
      \          |          /
       introspect  paginator, export, ...
             |
   bridge  adapters/  schemas/
      \      |
      vim-dadbod        state  (the sink)
```

`bridge.lua` is the only module that touches vim-dadbod. Two execution
paths live there: feature queries (introspection, FK lookups, export) run as
our own `vim.system` processes where dadbod only builds the argv, and user
queries go through `:DB` where dadbod owns the async job, writes the
`.dbout` file and fires the `DBExecutePre`/`Post` autocmds we hook.

## State

`state.lua` holds one Instance: the resolved config, the paths, and the
connection entries. `dbs_list` (discovery order) and `dbs` (keyed by
key_name) hold the SAME entry objects, one per connection.

A ConnectionEntry carries identity (name, url, group, source, key_name),
the live connection fields, a snapshot of its adapter's capabilities taken
at build time, and the introspected data containers (tables, schemas,
routines), which start empty and get filled lazily when the drawer expands
the connection.

Things easy to get wrong here:

- `entry.conn` is a tri-state: nil never tried, `''` failed, anything else
  is a live handle. A failed attempt must not read as connected.
- On repopulate, an entry survives (with its live handle and introspected
  data) when its key_name AND url are unchanged. Everything on an entry has
  to be derivable from (url, config) or it wont survive a store edit.
- Drawer expand state is NOT on entries. It lives in the drawer's expand
  map, keyed by stable ids, so it survives re-introspection.

## Connections

Discovery precedence: dotenv vars (`DB_UI_*`) -> `DBUI_URL` env ->
`g:db`/`g:dbs` -> connections.json. First (name, source, group) wins.
`connections.lua` is pure discovery + store transforms,
`connections_controller.lua` is the interactive layer over it (prompts,
confirms, only `file` source entries are mutable).

One rule worth knowing: the store persists the RAW url the user typed and
only validates against the resolved one. Resolving expands `$DB_PASS` style
references, and writing that to disk would leak plaintext secrets.

## Hooks and events

Two surfaces for the same lifecycle: `config.hooks` (single slot, set at
setup, `on_connect` can rewrite the url) and the runtime event bus
(`api.on`/`api.off`, multi subscriber, observe only). Every hook runs under
pcall, a throwing hook never aborts the operation it observes.

## Frozen contracts

`constants.lua` lists the identifiers we can never rename: `b:db`, the
`b:dbui_*` buffer vars, the `.dbout` filetype, `g:dbs`, the `DBUIOpened`
autocmd, `autoload/db_ui.vim`. They are compat contracts with vim-dadbod,
its completion plugin, and existing user configs.

Also frozen in spirit: the config table itself. After resolve it is
recursively read only, so a typo'd write fails loudly instead of silently
doing nothing.

## Gotchas that cross subsystems

- `vim.system` callbacks run in fast event context, where touching `vim.o.*`
  raises E5560. Anything post-process in a callback gets `vim.schedule`d
  (see `bridge.connect_async`).
- `bridge.run_many` leaves a nil hole in the results for a spawn that
  failed. Every consumer has to tolerate nil slots.
- Scratch buffer persistence has two halves that must agree: restore on
  startup (`state.make_entry`) and write on quit (the query controller's
  sweep). Both go through `persists_scratch`, keep it that way.
