# The drawer

The tree sidebar. Connections at the top, and under each one the sections
(new query, buffers, saved queries, schemas, routines), then a Query results
list at the bottom.

## Where the code lives

- [`lua/dadbod-ui/drawer/init.lua`](../lua/dadbod-ui/drawer/init.lua) - the
  Drawer class, window lifecycle, render orchestration. Its a session
  singleton, and it owns the lazy controllers (query, introspect,
  connections) so the dependency graph stays acyclic with `state` as the
  sink.
- [`lua/dadbod-ui/drawer/content.lua`](../lua/dadbod-ui/drawer/content.lua) -
  pure tree builders. No buffer or window calls in here, which is what makes
  the tree testable without opening a drawer.
- [`lua/dadbod-ui/drawer/paint.lua`](../lua/dadbod-ui/drawer/paint.lua) - the
  only half that writes to the buffer.
- [`lua/dadbod-ui/drawer/actions.lua`](../lua/dadbod-ui/drawer/actions.lua) -
  everything bound to a key (toggle, rename, delete, goto sibling, ...).
- [`lua/dadbod-ui/drawer/ids.lua`](../lua/dadbod-ui/drawer/ids.lua) - stable
  node ids for the expand map.
- content.lua and actions.lua are mixins: their methods get copied onto the
  Drawer class at load (init.lua:80).

## How a render works

1. Something calls `drawer:render()`. Triggers are opening the drawer, a
   BufEnter on it, a toggle, introspection results landing, connection CRUD,
   and spinner ticks.
2. `build_content()` builds a tree of Node tables (label, icon, type, action,
   children). A collapsed node just doesnt build children, so lazy data is
   never demanded early. The tree then gets flattened into `self.content`,
   one node per buffer line, with `node.index` = line number.
3. `paint()` diffs the new lines against the last painted snapshot and only
   rewrites the changed span. An identical render touches nothing, which is
   why the BufEnter re-render is safe and why the cursor never jumps. A
   spinner tick rewrites exactly one line through this same path, there is no
   second buffer-writing code path to keep in sync.
4. Highlights are extmarks computed per line from the node + painted text
   (`highlights.lua`), never syntax regexes.

Nodes are rebuilt wholesale every render. Only the ids are stable. So any
action that triggers a render must re-fetch its node from `self.content`
afterward, the old table is stale (see `goto_node` in actions.lua).

Expansion state lives in one place: the drawer's `expand` map, keyed by the
stable ids from ids.lua. Never on the connection entries. Thats why expand
state survives re-introspection and closing/reopening the drawer.

## Connection colors (#91)

`C` on a db line sets the connection's own `#rrggbb` color, `C` on a group
header sets the group's; empty input clears. The effective color (own wins
over group, resolved by `Instance:connection_color`) is stamped on the node
as `color` at build time (`name_len` gives the name's byte length), and
`highlights_for` paints exactly the name prefix of the label - status
glyphs and the `(…)` details suffix keep their own groups. The highlight
groups are dynamic `DadbodUIColor_<rrggbb>` definitions, defined once per
colorscheme generation: a `ColorScheme` autocmd in `highlights.lua` drops
the memo, so after a `:colorscheme` reset each group is re-defined by the
next paint (drawer) or winbar apply (buffer setup / BufWinEnter) that uses
it. The same color also paints the query-buffer winbar block (see
`query/init.lua`'s `connection_winbar`), as a background with black/white
text picked by luminance - after a `:colorscheme` it recovers the next
time the buffer enters a window, the same lifetime the default
`DadbodUIWinbarConnection` block already has. No color set means every one
of these surfaces renders exactly like before.

## Lazy introspection

Nothing is introspected at startup. Expanding a connection node fires
`on_expand`, which connects (async, via `bridge.connect_async`) and fans out
the schema/table/routine queries. A spinner frame is appended after the label
while that runs. Collapsing or closing the drawer stops the spinners so no
timer leaks. Exception: the sqlite `tables` call is blocking, so its spinner
frame freezes on the first frame. Thats expected, not a bug.

## Gotchas

- The paint diff key (`paint.lua`, the `keys[]` array) must encode every node
  field `highlights_for` reads besides the line text. If highlighting ever
  depends on a new node field, add it to the key or highlight-only changes
  get skipped by the diff.
- `open()` verifies the split actually produced a new window before turning
  it into a scratch buffer. A silently failed split (E36) would otherwise
  convert the users buffer into the drawer and overwrite it. Dont "simplify"
  that guard away.
- `node.expanded` is the state the node was built with, and toggle computes
  the new state by negating it. Dont mutate nodes after build.
- The drawer buffer can be visible in more than one window. `active_winid()`
  resolves which window's cursor to read, dont use `self.winid` directly in
  actions.
- `entry.conn` is a tri-state: nil means never tried, `''` means a failed
  attempt, a handle means live. A failed attempt must not read as connected.
- `rename_buffer` renames on disk before touching any tracking, so a failed
  rename mutates nothing.
