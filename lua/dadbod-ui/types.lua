---@meta
--- Shared type definitions for dadbod-ui. This file is annotations-only; it is
--- never `require`d at runtime (lua_ls reads it from the workspace).

---@alias DadbodUI.Source 'g:dbs' | 'env' | 'dotenv' | 'file'
---@alias DadbodUI.NotifyKind 'info' | 'warning' | 'error'
---@alias DadbodUI.BufferNameGenerator fun(opts: { label: string, table?: string, schema?: string, filetype: string }): string
---@alias DadbodUI.TableNameSorter fun(tables: string[]): string[]

--- A prompt function (vim.ui.input-shaped); injectable so specs drive the
--- interactive flows without a real UI. `on_confirm` receives nil on cancel.
---@alias DadbodUI.UiInput fun(opts: { prompt: string, default?: string }, on_confirm: fun(value: string|nil))

--- A yes/no prompt (notifications.confirm-shaped); injectable for the same reason.
---@alias DadbodUI.Confirm fun(msg: string): boolean

--- A picker (vim.ui.select-shaped); injectable so specs drive the edit flow.
--- `on_choice` receives nil when the user aborts the selection.
---@alias DadbodUI.UiSelect fun(items: any[], opts: { prompt?: string, format_item?: fun(item: any): string }, on_choice: fun(item: any|nil))

--- The `b:dbui_bind_params` contract: placeholder name -> the raw (unquoted)
--- value the user entered. Read by external tools, so the shape stays stable.
---@alias DadbodUI.BindParams table<string, string>

--- The buffer-local contract fields a query buffer carries, as passed to the
--- single contract writer (Query.write_contract). `table`/`schema` default to
--- '' when omitted; `bind_params` is written only when present and may be the
--- bare '' a never-parametrized buffer carries (dadbod-ui round-trips it through
--- the defensive read in query.lua), hence `string` as well as the dict.
---@class DadbodUI.ContractOpts
---@field table? string
---@field schema? string
---@field bind_params? DadbodUI.BindParams|string

--- Parsed connection URL (vim-dadbod's db#url#parse). Network urls carry
--- host/port/user/password/path; file-style urls (sqlite) carry opaque instead.
---@class DadbodUI.ParsedUrl
---@field scheme string  RAW scheme (e.g. 'postgres', not 'postgresql')
---@field host? string
---@field port? string
---@field user? string
---@field password? string
---@field path? string
---@field opaque? string
---@field params table<string, string>
---@field fragment? string

--- A discovered connection, normalized by dadbod-ui.connections.
---@class DadbodUI.ConnectionRecord
---@field name string
---@field url string  resolved url
---@field source DadbodUI.Source
---@field group string  '' when ungrouped
---@field key_name string  name_source, or group_name_source when grouped

--- A connections.json entry (stored form).
---@class DadbodUI.FileConnection
---@field name string
---@field url string
---@field group? string

-- Pure domain containers: drawer expand/collapse state lives in the drawer's
-- `expand` map (keyed by drawer/ids.lua ids), never on these.

--- The schemas collection for a connection: schema names in introspection
--- order, plus each schema's (sorted) table names.
---@class DadbodUI.SchemasNode
---@field list string[]
---@field items table<string, string[]>

--- A single stored procedure or function. `content` is the pre-built DDL/source
--- query for this routine (from the adapter's `routine_definition`), so opening
--- the drawer node reuses the table-helper open path verbatim (fill a query
--- buffer with `content`, run it to view the source).
---@class DadbodUI.RoutineItem
---@field name string
---@field kind 'procedure' | 'function'
---@field content string  the DDL/source query that renders this routine's definition

--- The stored procedures / functions collection for a connection (M-routines).
--- Schema-supporting adapters populate `list`/`items` (schema names -> routines,
--- mirroring `DadbodUI.SchemasNode`); flat adapters (mysql-with-db) populate
--- `flat`. Empty for adapters with no routine support (e.g. sqlite).
---@class DadbodUI.RoutinesNode
---@field list string[]  schema names that own routines (schema adapters)
---@field items table<string, DadbodUI.RoutineItem[]>  per-schema routines (schema adapters)
---@field flat DadbodUI.RoutineItem[]  routines, ungrouped (non-schema adapters)

--- One "Script As" action for a routine (e.g. `CREATE To`, `DROP To`,
--- `EXECUTE To`). `query` fetches the action's input from the database (absent =>
--- build from the name/kind alone, no round-trip); `parse` turns that raw output
--- into whatever `build` wants (defaults to reassembling statement text);
--- `build` produces the final DDL.
---@class DadbodUI.RoutineScript
---@field label string  menu label, shown under the routine's "Script As" node
---@field query? fun(schema: string, name: string, kind: string): string  SQL fetching this action's input
---@field args? string[]  CLI args replacing the adapter's for this action's fetch (when the query needs different output formatting, e.g. sqlserver's untruncated `-y 0` mode)
---@field parse? fun(lines: string[]): any  parse the query output (default: reassemble statement text)
---@field build? fun(ctx: DadbodUI.RoutineScriptCtx): string  produce the DDL text (default: return the fetched data unchanged)

--- The context handed to a `DadbodUI.RoutineScript.build`. `data` is the parsed
--- result of the action's `query` (nil for a query-less action).
---@class DadbodUI.RoutineScriptCtx
---@field schema string
---@field name string
---@field kind 'procedure' | 'function'
---@field data? any  the parsed result of the action's `query` (e.g. source text, or a `DadbodUI.RoutineParam[]`)

--- One routine parameter, parsed from an adapter's parameter query.
---@class DadbodUI.RoutineParam
---@field name string  parameter name (e.g. '@id')
---@field type string  SQL type name (e.g. 'int')

--- An adapter's "Script As" capability: the ordered scripting actions. Absent on
--- adapters that don't support DDL scripting -- their routine nodes stay plain
--- open leaves.
---@class DadbodUI.RoutineScripts
---@field actions DadbodUI.RoutineScript[]  ordered scripting actions

--- One database adapter, registered under its canonical `name` and every
--- `aliases` entry (dadbod-ui.adapters). The single per-scheme registry: each
--- capability module (schemas, table_helpers, explain, paginator,
--- export_adapters) reads its data from here, so adding an adapter is one file
--- (or one `adapters.register` call) and aliasing is resolved exactly once.
--- Every capability field is optional -- an absent field means the adapter
--- doesn't support that feature.
---@class DadbodUI.Adapter
---@field name string  canonical adapter name (also a valid url scheme)
---@field aliases? string[]  other url schemes that resolve to this adapter (e.g. 'postgresql')
---@field schema? fun(config?: DadbodUI.Config): DadbodUI.SchemaAdapter  introspection SQL + parsers + dbout metadata
---@field table_helpers? table<string, string>|fun(config: DadbodUI.Config): table<string, string>  helper name -> SQL template
---@field explain? DadbodUI.ExplainTemplates  EXPLAIN templates ({sql} placeholder)
---@field pagination? 'limit_offset'|'limit_comma'  LIMIT clause style (absent: no pagination)
---@field statements? DadbodUI.StatementPatterns  dialect keywords for the statement classifier; ABSENT means the dialect is not SQL (mongodb) and classify() answers "cannot tell" instead of guessing
---@field export? { stdin: boolean, extract: string[], native: table<string, string[]> }  CLI export flags
---@field db_path_lists_tables? boolean  a url naming a database in its path lists tables directly instead of schemas (mysql/mariadb)
---@field normalize_tables? fun(raw: string[]): string[]  clean dadbod's raw `tables` output (sqlite splitting, mysql header filter)

--- An adapter's EXPLAIN forms, all carrying the literal `{sql}` placeholder.
--- `plain`/`analyze` produce the human-readable text plan (dadbod-ui.explain's
--- original capability). The `json` pair produces the machine-readable plan the
--- explain tree renders; adapters without a structured plan format simply omit
--- them. `json_args` is the extra CLI argv that makes the client emit the raw
--- JSON document instead of its human table framing (psql's `-Aqt`), mirroring
--- how `SchemaAdapter.args` keeps introspection output parseable.
---@class DadbodUI.ExplainTemplates
---@field plain string
---@field analyze? string  executing form with real timings; absent when the dialect has none
---@field json? string     structured-plan form (e.g. EXPLAIN (FORMAT JSON))
---@field json_analyze? string  executing structured form; wrap DML safely (BEGIN/ROLLBACK) where the dialect allows
---@field json_args? string[]   extra client argv for raw, parseable JSON output

--- Dialect extensions to the statement classifier's shared SQL core
--- (dadbod-ui.classifier). An empty table is meaningful: it declares "this
--- dialect is plain SQL, the shared core applies as-is".
---@class DadbodUI.StatementPatterns
---@field changing? string[]   extra mutating keywords beyond the shared core (e.g. oracle PURGE)
---@field dangerous? string[]  extra always-dangerous keywords beyond the shared core (each implies changing)

--- Per-adapter introspection metadata (dadbod-ui.schemas). M6 uses the
--- schema/table listing fields, M10 uses the dbout foreign-key / cell / layout
--- fields below.
---@class DadbodUI.SchemaAdapter
---@field args? string[]              extra argv appended to the adapter command
---@field schemes_query? string       SQL listing schema names
---@field schemes_tables_query? string  SQL listing (schema, table) pairs
---@field procedures_query? string     SQL listing (schema, routine_name, kind) rows; kind is 'procedure'|'function'. Absent => the adapter has no stored procedures (e.g. sqlite): a clean no-op.
---@field tables_procedures_query? string  same shape as `procedures_query`, scoped to the connected database -- used on the tables-only path (e.g. mysql url naming a database) so routines from other schemas don't leak in. Falls back to `procedures_query` when absent.
---@field routine_definition? fun(schema: string, name: string, kind: string): string  SQL that renders one routine's DDL/source (identifiers escaped)
---@field routine_scripts? DadbodUI.RoutineScripts  SSMS-style "Script As" capability (absent => routine nodes open the definition query instead)
---@field parse_results? fun(results: string[], min_len: integer): any[]
---@field default_scheme? string
---@field quote? boolean  whether the adapter quotes identifiers (postgres/oracle/clickhouse do; mysql/sqlserver do not)
---@field filetype? string
---@field requires_stdin? boolean
---@field callable? string            'interactive' (default) | 'filter'
--- dbout (result-buffer) metadata, used by dadbod-ui.dbout for folding + cell /
--- foreign-key navigation. The SQL must match the exact result layout dadbod
--- renders (the "correct SQL" interop contract); the patterns are Vim regexes.
---@field foreign_key_query? string   SQL resolving a column's foreign table; carries the `{col_name}` placeholder
---@field select_foreign_key_query? string  string.format template (schema, table, column, value) for the jump SELECT
---@field cell_line_number? integer   first possible separator (column-underline) line
---@field cell_line_pattern? string   Vim regex matching a separator line
---@field layout_flag? string         CLI flag toggling expanded/vertical result layout

--- One highlight range to apply over a painted drawer line: a highlight group
--- and the byte columns it covers (`col_end` exclusive). Computed purely by
--- dadbod-ui.highlights so it is unit-testable without a buffer.
---@class DadbodUI.Highlight
---@field group string
---@field col_start integer  0-based byte column
---@field col_end integer    0-based byte column, exclusive

--- Per-connection state entry held by the instance.
---@class DadbodUI.ConnectionEntry
---@field url string
---@field source DadbodUI.Source
---@field name string
---@field group string
---@field key_name string
---@field save_name string  group-qualified identifier ({group}_{name} when grouped); names the save folder + tmp query folder
---@field scheme string  raw adapter scheme
---@field db_name string
---@field save_path string
---@field tmp_path string  this connection's tmp query folder (<tmp_location>/<save_name>); the ownership record for scratch buffers
---@field conn? string  live connection handle, set when connected
---@field conn_error? string  last connection error, if any
---@field connect_ms? integer  elapsed ms of the last successful connect (shown in the details view, not a popup)
---@field conn_tried boolean  whether a connection was attempted
---@field loading? boolean  transient: connecting/introspecting (drawer shows the loading icon); cleared on data-land/error
---@field schema_support boolean  does the adapter expose schemas
---@field quote boolean  whether the adapter quotes identifiers
---@field default_scheme string  the adapter's default schema name
---@field filetype string  query-buffer filetype for this adapter
---@field extension string  adapter's query-input file extension (names generated buffers so external tooling attaches)
---@field table_helpers table<string, string>  helper name -> SQL template
---@field tables string[]  introspected table names (flat, across schemas)
---@field schemas DadbodUI.SchemasNode
---@field routines DadbodUI.RoutinesNode  stored procedures / functions for this connection
---@field routine_support boolean  does the adapter expose stored procedures/functions
---@field routine_scripts? DadbodUI.RoutineScripts  the adapter's "Script As" capability (nil => plain open-definition routine leaves)
---@field buffers string[]  open query buffers for this connection (full file paths)
---@field saved_queries string[]  persisted saved-query file paths under save_path

-- Behavioural controllers are declared module-locally (like `Instance` in
-- state.lua and `Drawer` in drawer.lua), each with a single `---@class` above
-- its table so its methods type-check in place:
--   DadbodUI.Introspect             -> lua/dadbod-ui/introspect.lua
--                                      (connect + schema/table introspection)
--   DadbodUI.ConnectionsController  -> lua/dadbod-ui/connections_controller.lua
--                                      (interactive connections.json CRUD)
--
-- The loading spinner (dadbod-ui.spinner) is a leaf module, not a class: it owns
-- the braille frames/interval and a registry of named libuv timers, each entry a
-- `{ timer: uv.uv_timer_t, tick: fun(): nil }`. It requires nothing from the project,
-- so its shapes are kept inline rather than shared here.

--- Public connection summary (connections_list()).
---@class DadbodUI.ConnectionInfo
---@field name string  display name (not unique across groups)
---@field group string  group name ('' when ungrouped)
---@field key_name string  unique key ({group}_{name}_{source} when grouped, else {name}_{source})
---@field url string
---@field is_connected boolean
---@field source DadbodUI.Source

--- A drawer tree node. Builders create it with `children` (only when
--- expanded); the flatten step assigns `level` (tree depth), `parent` and
--- `index` (its line number / position in the flat content[] projection).
---@class DadbodUI.Node
---@field label string
---@field icon string
---@field type string  'group'|'db'|'query'|'schemas'|'tables'|'schema'|'table'|'table_helper'|'routines'|'routine_schema'|'routine'|'routine_script_as'|'routine_script'|'buffer'|'saved_query'|'buffers'|'saved_queries'|'dbout'|'dbout_list'|'help'|'add_connection'|...
---@field action string  'toggle'|'open'|'activate'|'noaction'
---@field id? string  stable expand-map id (drawer/ids.lua); present on every toggle node
---@field children? DadbodUI.Node[]  built only when the node is expanded
---@field level? integer  tree depth; assigned by the flatten step
---@field parent? DadbodUI.Node  assigned by the flatten step (nil for roots)
---@field index? integer  line number in the flat content[] projection; assigned by the flatten step
---@field key_name? string
---@field group? string
---@field expanded? boolean  the expand state the node was built with
---@field on_expand? fun()  fired when a toggle opens the node (db lazy introspection)
---@field on_collapse? fun()  fired when a toggle closes the node (db spinner cleanup)
---@field on_activate? fun()  the whole action for an `activate` node (e.g. Add connection)
---@field table? string  table name (table / table_helper nodes)
---@field schema? string  schema name (table / table_helper nodes)
---@field content? string  helper SQL template (table_helper nodes)
---@field file_path? string  on-disk path (buffer / saved_query / dbout nodes)
---@field saved? boolean  true for saved-query nodes (vs tmp/open buffers)
---@field detail? boolean  the label ends in a `(…)` detail suffix (stamped where the suffix is appended; renders dimmed)
---@field loading_frame? string  trailing spinner frame for a connecting db node (appended after the label; animated in place by repaint_db_node)

--- A command spec for the bridge concurrency helpers.
---@class DadbodUI.CommandSpec
---@field cmd string[]
---@field stdin? string

--- The canonical export intermediate (dadbod-ui.export_extract): a faithful,
--- string-typed view of a result set parsed from a CLI's delimited output. SQL
--- NULL is the `export_formats.NULL` sentinel, never a Lua nil (arrays cannot hold
--- nil holes, and a real NULL must be distinguishable from an empty string).
---@class DadbodUI.ExportData
---@field columns string[]   column names, in order
---@field rows table[]       each row is an array of (string | export_formats.NULL)
---@field source? string     table/query name, for JSON-wrap + SQL INSERT target

--- Parameters for dadbod-ui.export.export (one result export).
---@class DadbodUI.ExportOpts
---@field url string         resolved connection url
---@field scheme string      raw adapter scheme
---@field format string      'csv'|'tsv'|'json'|'markdown'|'html'|'xml'|'sql'
---@field query string       the SQL to re-run for export
---@field path string        output file
---@field source? string     table/query name (JSON-wrap + SQL target)
---@field prefer_native? boolean  native passthrough when available (DECISION-001)
---@field format_opts? table  per-format options (see dadbod-ui.export_formats)

--- The `export` config block (see config defaults + specs/native-export.md §11).
---@class DadbodUI.ExportConfig
---@field prefer_native? boolean
---@field default_path? string  '' => cwd, else a directory
---@field coerce_numbers? boolean
---@field csv? table
---@field tsv? table
---@field json? table

--- Payload passed to on_pre/on_post subscribers.
---@class DadbodUI.ExecuteEvent
---@field output_file string
---@field match string

--- Pagination state carried by a `.dbout` result buffer (`b:dbui_page`). Set when
--- a paginated query is executed and read by the `[` / `]` re-execute handlers so
--- a result knows the SQL, adapter and page that produced it. `url` is the
--- resolved connection string (dadbod's `b:db` for the query buffer / entry.conn).
---@class DadbodUI.PageState
---@field original_sql string  the un-paginated SQL (re-paginated per page step)
---@field page integer  1-based current page
---@field page_size integer  rows per page
---@field scheme string  raw adapter scheme
---@field url string  resolved connection url (for re-execution through bridge)
---@field last? boolean  true when this page returned < page_size rows (no next page); unset when the row count is unknown

--- Inputs you can inject into connections.discover (tests/overrides).
---@class DadbodUI.DiscoverInputs
---@field env? table<string, string>
---@field g_db? any
---@field g_dbs? any
---@field file_entries? DadbodUI.FileConnection[]
---@field on_dup? fun(name: string, source: string)

--- Per-call options for dadbod-ui.notifications.
---@class DadbodUI.NotifyOpts
---@field echo? boolean   force the :echo backend for this call
---@field title? string   override the '[Dadbod-UI]' title
---@field delay? integer  notify timeout in ms (honored by nvim-notify)

--- The effective icon set (dadbod-ui.icons).
---@class DadbodUI.Icons
---@field expanded table<string, string>
---@field collapsed table<string, string>
---@field saved_query string
---@field new_query string
---@field tables string
---@field procedures string  leaf glyph for a stored procedure / function node
---@field buffers string
---@field group string  standalone group/folder glyph (shown in the details line)
---@field add_connection string
---@field connection_ok string
---@field connection_error string

--- Configuration surface. Annotate a `setup{}` / lazy `opts` table with this
--- (`---@type DadbodUI.Config`); every field is optional, since defaults fill the
--- rest -- so lua_ls never flags a field you didn't set as missing. Internal code
--- reads the resolved config through this same type (optional fields read as
--- non-nil, so no nil-checks are needed at the call sites).
---@class DadbodUI.Config
---@field save_location? string
---@field tmp_query_location? string
---@field table_helpers? table<string, table<string, string>>
---@field table_helpers_order? string[]  display order for a table's helpers
---@field env_variable_url? string
---@field env_variable_name? string
---@field dotenv_variable_prefix? string
---@field icons? table
---@field use_nerd_fonts? boolean
---@field use_postgres_views? boolean
---@field hide_schemas? string[]
---@field is_oracle_legacy? boolean
---@field bigquery_region? string  the BigQuery region whose INFORMATION_SCHEMA introspection reads (default 'region-us')
---@field debug? boolean
---@field picker? 'auto'|'snacks'|'telescope'|'fzf'|'fallback'  connection picker backend (api.pick)
---@field notifications? DadbodUI.NotificationsConfig
---@field drawer? DadbodUI.DrawerConfig
---@field query? DadbodUI.QueryConfig
---@field results? DadbodUI.ResultsConfig
---@field actions? table<string, DadbodUI.Action>  user-defined named actions
---@field buffer_name_generator? DadbodUI.BufferNameGenerator
---@field table_name_sorter? DadbodUI.TableNameSorter
---@field hooks? DadbodUI.Hooks

--- Notification presentation + routing (`notifications`).
---@class DadbodUI.NotificationsConfig
---@field force_echo? boolean
---@field disable_info? boolean
---@field use_nvim_notify? boolean
---@field disable_progress_bar? boolean

--- The drawer/sidebar window (`drawer`).
---@class DadbodUI.DrawerConfig
---@field width? integer
---@field position? 'left'|'right'
---@field show_help? boolean
---@field show_database_icon? boolean
---@field expand_groups? boolean
---@field sections? string[]
---@field keys? DadbodUI.Keymaps  `lhs -> action`, or `false` to disable the context

--- SQL/query buffers (`query`).
---@class DadbodUI.QueryConfig
---@field default_query? string
---@field execute_on_save? boolean
---@field auto_execute_table_helpers? boolean
---@field bind_param_pattern? string
---@field save_on_exit? 'auto'|'ask'|'discard'  modified SCRATCH buffers on quit; saved queries always prompt
---@field show_buffer_connection? boolean  right-aligned `group/name` winbar on query buffers
---@field keys? DadbodUI.Keymaps  `lhs -> action`, or `false` to disable the context

--- `.dbout` result buffers (`results`).
---@class DadbodUI.ResultsConfig
---@field page_size? integer  rows per result page (M-pagination LIMIT/OFFSET)
---@field layout? 'horizontal'|'vertical'  split direction for the `.dbout` result window
---@field list_sort? 'asc'|'desc'
---@field query_time? DadbodUI.QueryTimeConfig
---@field export? DadbodUI.ExportConfig
---@field keys? DadbodUI.Keymaps  `lhs -> action`, or `false` to disable the context

--- Inline post-execute feedback (time + row count). See `query_time` in the
--- config defaults.
---@class DadbodUI.QueryTimeConfig
---@field enabled? boolean  master switch; also gates suppression of dadbod's echoes
---@field result_buffer? boolean  virtual line at the top of the `.dbout` buffer
---@field query_buffer? boolean  ghost text trailing the executed line in the SQL buffer
---@field show_row_count? boolean  append `· N rows` to the summary

--- The most recently executed query and its wall-clock runtime, surfaced by
--- `api.buf.last_query_info` and the dbout branch of `statusline`. `last_query_time`
--- is dadbod's `b:db.runtime` (seconds, as a string) recorded when the async
--- result lands, or `''` before any query finished.
---@class DadbodUI.LastQueryInfo
---@field last_query string[]  lines of the most recently executed query
---@field last_query_time string  runtime in seconds ('' before any result)

--- Options for `require('dadbod-ui').statusline()` (the `db_ui#statusline()`
--- opts dict). All optional.
---@class DadbodUI.StatuslineOpts
---@field prefix? string  leading text (default 'Dadbod-UI: ')
---@field separator? string  joiner between the shown fields (default ' -> ')
---@field show? string[]  fields to show, in order (default { 'db_name', 'schema', 'table' })

--- Where a query was executed from, so the post-execute summary can trail ghost
--- text on that line (dadbod-ui.dbout).
---@class DadbodUI.QueryOrigin
---@field bufnr integer  the SQL query buffer
---@field lnum integer  1-based line the cursor was on at execute time

--- The connect-hook event. `on_connect` receives it BEFORE the connection is
--- established (and may return a rewritten `url` string -- e.g. `$password`
--- swapped for a real secret -- which is what actually gets connected).
--- `on_connect_post` receives it AFTER, with the outcome fields populated.
---@class DadbodUI.ConnectEvent
---@field url string  the target connection url (return a string from on_connect to rewrite it)
---@field name string  the connection's display name
---@field key_name string  the connection's state key
---@field group string  the connection's group ('' when ungrouped)
---@field success? boolean  (on_connect_post) whether the connect succeeded
---@field conn? string  (on_connect_post) the live connection handle, on success
---@field error? string  (on_connect_post) the error message, on failure

--- The pre-execute-hook event (`on_execute_query`), fired before the SQL is
--- dispatched to the engine.
---@class DadbodUI.QueryEvent
---@field sql string[]  lines of SQL about to execute
---@field url string  the resolved connection url ('' for an unattached buffer)
---@field name string  the connection's display name ('' when unattached)
---@field key_name string  the connection's state key ('' when unattached)
---@field bufnr integer  the query buffer the execution came from
---@field is_visual boolean  true when running a visual selection

--- The post-execute-hook event (`on_execute_query_post`), fired once the result
--- has landed in the `.dbout` buffer. `rows()` reads the result output lazily (so
--- a hook that only wants the status/timing pays nothing), letting a hook persist
--- results elsewhere. `query` is the executed statement (the result's input file).
---@class DadbodUI.QueryResultEvent
---@field output_file string  the `.dbout` result file path
---@field rows fun(): string[]  read the result rows (from the loaded buffer or the output file)
---@field query string[]  lines of the query that produced this result ('' when unknown)
---@field runtime? number  wall-clock seconds (dadbod's b:db.runtime), nil if unknown
---@field exit_status? integer  the query exit status (0 = ok)

--- The cancel-hook event (`on_cancel_query` / `on_cancel_query_post`), fired
--- around a query cancel. Only fired when there is a cancellable async
--- query (gated on `bridge.can_cancel()`).
---@class DadbodUI.CancelEvent
---@field bufnr integer  the query buffer whose running async query is being cancelled

--- Any event passed to a hook -- the union `dadbod-ui.hooks` dispatches over.
---@alias DadbodUI.HookEvent DadbodUI.ConnectEvent|DadbodUI.QueryEvent|DadbodUI.QueryResultEvent|DadbodUI.CancelEvent

--- User-configurable lifecycle hooks (`config.hooks`). Every hook is optional; a
--- missing one is a clean no-op. Two hooks are transforms whose return value is
--- consumed: `on_connect` rewrites the connection url before connecting (the
--- password use case), and `resolve_bind_params` supplies bind-param values before
--- prompting. The `on_*` lifecycle hooks are observers -- their return value is
--- ignored. A throwing hook is caught and notified, never aborting the underlying
--- connect / execute / cancel.
---@class DadbodUI.Hooks
---@field on_connect? fun(event: DadbodUI.ConnectEvent): string|nil  before connect; return a string to rewrite the url
---@field on_connect_post? fun(event: DadbodUI.ConnectEvent)  after connect (success/error on the event)
---@field on_execute_query? fun(event: DadbodUI.QueryEvent)  before the SQL is dispatched
---@field on_execute_query_post? fun(event: DadbodUI.QueryResultEvent)  after the result lands (read/persist rows)
---@field on_cancel_query? fun(event: DadbodUI.CancelEvent)  before a running query is cancelled
---@field on_cancel_query_post? fun(event: DadbodUI.CancelEvent)  after a running query is cancelled
---@field resolve_bind_params? fun(names: string[], known: DadbodUI.BindParams): table<string, string>|nil  supply bind-param values before prompting; return a name->value map (partial ok), nil/omitted prompts for all

--- A context's keymaps: `lhs -> action`, or `false` to disable every mapping in
--- that context. Merged over the defaults, so a partial table rebinds/adds/
--- disables individual keys without redeclaring the rest.
---@alias DadbodUI.Keymaps table<string, DadbodUI.KeySpec>|false

--- What a `keys` entry binds to: an action name (a built-in id or a key in
--- `config.actions`), `{ '<action>', mode = ... }` to bind in specific mode(s)
--- (default `'n'`), or `false` to disable just that key.
---@alias DadbodUI.KeySpec string|{ [1]: string, mode?: string|string[] }|false

--- A user-defined action (`config.actions[name]`): a bare function, or a
--- `{ desc, fn }` table so it also shows in the `?` help window. The function
--- receives a per-context action context and (for query/results) is invoked with
--- the triggering mode on `ctx.mode`.
---@alias DadbodUI.Action fun(ctx: DadbodUI.ActionContext)|{ desc: string, fn: fun(ctx: DadbodUI.ActionContext) }

--- The context object passed to a user action. Common fields plus context-
--- specific handles: `drawer`/`item` in the drawer, `query` in a query buffer.
---@class DadbodUI.ActionContext
---@field mode string  the triggering mode ('n', 'v', 'o', ...)
---@field bufnr integer  the buffer the action fired in
---@field connection? DadbodUI.ConnectionEntry  the resolved connection, when one applies
---@field drawer? DadbodUI.Drawer  the drawer instance (drawer context only)
---@field item? DadbodUI.Node  the node under the cursor (drawer context only)
---@field query? DadbodUI.Query  the query controller (query context only)
