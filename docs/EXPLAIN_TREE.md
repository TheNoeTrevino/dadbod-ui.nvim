# EXPLAIN Plan Tree (issue #93)

`EXPLAIN (FORMAT JSON)` rendered as an interactive tree in its own split:
cost, estimated vs actual rows, timing, with expensive nodes visually hot.
Implemented for postgres, mysql and mariadb; every other adapter reports
itself honestly unsupported through the existing `explain.supports` gating.

## Module layout

```
lua/dadbod-ui/explain/
  init.lua        the EXPLAIN template capability (wrap, supports, json_args)
  run.lua         orchestration seam: wrap -> client -> decode -> open tree
  plan.lua        decode dispatch + the derived metrics (exclusive time, heat, skew)
  parsers/
    postgres.lua  EXPLAIN (FORMAT JSON) -> PlanNode
    mysql.lua     EXPLAIN FORMAT=JSON (query_block shape, MariaDB included) -> PlanNode
  render.lua      pure: annotated plan -> ExplainRow[] (line text + highlight ranges)
  tree.lua        the window: scratch buffer, keymaps, collapse state, floats
```

Dependency direction stays acyclic: `explain/*` depends on `bridge`,
`adapters`, `highlights`, `icons`, `float`, `config`; nothing depends on
`explain/*` except the facade/API/mappings layers, and those require the tree
stack lazily -- it loads when a plan tree is first opened, not at plugin
entry.

## Execution path (headless, not `.dbout`)

`Query:explain_query` (the text form) runs wrapped SQL through `:DB` and lands
in a `.dbout` buffer. The tree does NOT use that path; it uses the headless
dual that introspection/export already use:

1. Resolve SQL exactly like `execute_query`: buffer lines or visual selection
   via `get_lines`, then `with_resolved_sql` for bind params.
2. Wrap: `explain.wrap(scheme, sql, { format = 'json', analyze = ... })`,
   reading the adapter spec's `explain` fields:
   ```lua
   explain = {
     plain   = 'EXPLAIN {sql}',
     analyze = 'EXPLAIN ANALYZE {sql}',
     json    = 'EXPLAIN (FORMAT JSON) {sql}',
     -- ANALYZE executes the statement; postgres runs it in a rolled-back
     -- transaction so analyzed DML never commits:
     json_analyze = 'BEGIN; EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) {sql}; ROLLBACK;',
     -- per-purpose CLI args, same pattern as schema.args / export.extract:
     json_args = { '--no-psqlrc', '--set=ON_ERROR_STOP=1', '-q', '-A', '-t' },
     -- module path of the dialect's plan parser; json support = template AND parser
     parser = 'dadbod-ui.explain.parsers.postgres',
   }
   ```
   `json == nil` (or no `parser`) ⇒ the tree reports unsupported for that
   adapter, reusing the `wrap` error convention; `analyze` without a
   `json_analyze` fails the same way. mariadb derives mysql's block and
   overrides only its executing forms (`ANALYZE {sql}`,
   `ANALYZE FORMAT=JSON {sql}` -- real per-node `r_*` timings).
3. Run: `bridge.query_command(conn, wrapped, json_args)` through
   `bridge.run_many` (async -- the main loop never blocks; the tree opens from
   the exit callback). A non-zero exit or stderr-reported SQL error surfaces
   as a notification, tree unopened.
4. Parse: `vim.json.decode` → the spec-declared parser → normalized
   `PlanNode` tree → derived metrics.

Why `json_args` matters: psql's default output renders the JSON as an aligned
table with `+` continuation markers -- unparseable. `-A -t` yields the raw
document (`-q` also suppresses the BEGIN/ROLLBACK command tags), exactly as
`schema.args` does for introspection; `--no-psqlrc` for the same injection
reason `export` cites; `ON_ERROR_STOP` makes SQL errors exit non-zero so they
surface as notifications instead of decoding as garbage. The mysql client
equivalent is `--skip-table --batch --raw --skip-column-names`.

## Normalized plan model

One dialect-agnostic node shape (see `DadbodUI.PlanNode` in `types.lua`) so
the renderer never branches on adapter: `op`, the scanned
`relation`/`alias`/`cte_name`/`index_name`, `total_cost`, `plan_rows`,
ANALYZE actuals (`actual_rows`, `actual_time_ms`, `loops`), `exprs` (ordered
label→deparsed-text pairs: Filter, Index Cond, Sort Key, ...), `children`,
and `raw` -- the node's own adapter keys with child/structure keys stripped
by the parser, i.e. exactly the detail-float payload.

Computed once after parse, in `plan.lua` (pure, unit-testable):

- **exclusive time** = `actual_time_ms * loops − Σ child(actual_time_ms * loops)`
  (clamped ≥ 0) -- the number that actually finds the slow node.
- **heat** = exclusive share of the root total (time when analyzed, cost
  otherwise) -- the renderer's color signal.
- **estimate skew** = `actual_rows*loops / plan_rows` -- the misestimate
  signal (stale statistics) flagged past `config.explain.skew_threshold`.

MySQL's `EXPLAIN FORMAT=JSON` is shaped completely differently
(`query_block` wrapper keys + `table` leaves, costs as strings in
`cost_info`). Its parser normalizes both MySQL's and MariaDB's spellings into
the same `PlanNode`; fields a dialect can't provide stay nil and the renderer
degrades per-field, not per-adapter. Unknown wrapper keys whose value is
clearly nested plan structure still become labeled children instead of
silently truncating the tree.

## Rendering and the tree window

The render/window split mirrors the drawer's purity contract: `render.rows`
is pure (annotated plan → `ExplainRow[]`, line text plus exact byte-range
highlights, computed while the line is assembled), and `tree.lua` is the only
buffer-touching half -- full repaint per change, since plans are tens of
rows. Row N of the buffer is `rows[N]`, so the cursor row IS the plan node.
Collapse state is view-owned (tree-path row ids like `1.2.1`), reset per
plan.

A row reads as cells separated by a dim ` · `:

```
├─ Seq Scan on orders o · Filter: (status = 'open') · rows 1000 (est 10 ⚠×100) · 850ms 94%
```

op + target (`on table alias`, `on cte name`, `using index`), the node's
conditions (truncated to a byte budget; the full text lives in the detail
float), rows -- actuals when analyzed, `rows ~N` estimates otherwise, with
the `(est N ⚠×skew)` marker on a misestimate -- and the node's OWN time
(exclusive of children) with its share of the whole plan; plain plans show
`cost N` cells instead. The summary header carries planning/execution times
and `analyzed` vs `estimates only`.

Highlight groups (all `default = true` links, defined in
`highlights.define`): `DadbodUIExplainTree` (glyphs/separators),
`...Op`, `...Target`, `...Expr`, `...Rows`, `...Skew`, `...Summary`, and the
heat tiers `...Cold`/`...Mild`/`...Warm`/`...Hot` on the time cell --
warm/hot thresholds from `config.explain.heat`. The collapsed-fold marker
resolves through the icon set (`icons.collapsed.explain`), so user icon
overrides apply.

Window: a split sharing the tabpage with the query buffer (query + plan
visible together). `position` picks the orientation -- `top`/`bottom` split
horizontally (`height`), `left`/`right` vertically (`width`); default
`bottom`.

## Config and keymaps

The `explain` context is wired like every other (`config.contexts`,
`builtin_actions`, `action_order`, a `keys` block). Defaults:

```lua
explain = {
  position = 'bottom',       -- top/bottom = horizontal, left/right = vertical
  width = 72, height = 15,   -- width when vertical, height when horizontal
  heat = { warn = 0.2, hot = 0.5 },   -- exclusive-share fractions
  skew_threshold = 100,      -- est-vs-actual ratio for the ⚠ marker
  keys = {
    ['<CR>'] = 'toggle_node',
    ['K']    = 'node_details',   -- full raw detail in a float
    ['q']    = 'close',
    ['?']    = 'help',
  },
},
query = { keys = {
  ['<Leader>P'] = { 'explain_tree', mode = { 'n', 'v' } },
  ['<Leader>A'] = { 'explain_tree_analyze', mode = { 'n', 'v' } },  -- runs the query (rolled back for DML)
}},
```

Config owns the policy numbers: the renderer takes heat/skew/fold-glyph as
required opts and never restates defaults.

Entry points, both funneling through `run.open_tree`:
`api.explain_tree(name, sql, opts?)` (connects first if needed; synchronous
`false, err` for pre-flight failures like an unsupported adapter) and
`api.buf.explain_tree()` / `api.buf.explain_tree_selection()` on the current
query buffer (same connect-if-needed policy), plus the facade duals backing
the keymaps.

## Adapter support matrix

| Adapter | JSON plan | Tree | Notes |
| --- | --- | --- | --- |
| postgres | `EXPLAIN (FORMAT JSON)` | full | `BUFFERS` free with analyze; DML analyze rolled back |
| mysql ≥5.7 | `EXPLAIN FORMAT=JSON` | full | no executing JSON form (`EXPLAIN ANALYZE` emits TREE text -- parse later, not now) |
| mariadb | `EXPLAIN FORMAT=JSON` | full | `ANALYZE FORMAT=JSON` gives real per-node `r_*` timings |
| sqlite | `EXPLAIN QUERY PLAN` | flat text, no JSON | stays on the existing plain path |
| sqlserver / oracle / bigquery / mongodb | ✗ (xml/table shaped) | ✗ | honestly unsupported per the issue |

## Testing

- Parsers and metrics: inline JSON fixtures in `tests/explain/plan_spec.lua`
  and `tests/explain/mysql_plan_spec.lua`, pure decode→normalize→assert.
- Render: row text + highlight ranges computed buffer-free
  (`tests/explain/render_spec.lua`), same posture as `highlights_spec.lua`.
- Window and wiring: `tests/explain/tree_spec.lua` (real windows, no DB) and
  `tests/explain/wiring_spec.lua` (keymap/api plumbing, stubbed bridge).
- End to end: `integration/query/explain_tree_spec.lua` drives the real
  clients against live servers per JSON-capable adapter -- tree render,
  error path, analyzed timings, and the postgres proof that analyzed DML
  rolls back.
