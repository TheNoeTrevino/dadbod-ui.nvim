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

--- Expand state for a single table node.
---@class DadbodUI.TableItem
---@field expanded boolean

--- A tables collection: `{ expanded, list, items }`.
---@class DadbodUI.TablesNode
---@field expanded boolean
---@field list string[]
---@field items table<string, DadbodUI.TableItem>

--- A connection's open query buffers. `list` holds full buffer file paths;
--- `tmp` is the subset living in the tmp-query location.
---@class DadbodUI.BuffersNode
---@field expanded boolean
---@field list string[]
---@field tmp string[]

--- A connection's persisted saved queries. `list` holds full file paths under
--- the connection's save_path.
---@class DadbodUI.SavedQueriesNode
---@field expanded boolean
---@field list string[]

--- A single schema and the tables under it.
---@class DadbodUI.SchemaItem
---@field expanded boolean
---@field tables DadbodUI.TablesNode

--- The schemas collection for a connection.
---@class DadbodUI.SchemasNode
---@field expanded boolean
---@field list string[]
---@field items table<string, DadbodUI.SchemaItem>

--- A single stored procedure or function. `content` is the pre-built DDL/source
--- query for this routine (from the adapter's `routine_definition`), so opening
--- the drawer node reuses the table-helper open path verbatim (fill a query
--- buffer with `content`, run it to view the source).
---@class DadbodUI.RoutineItem
---@field name string
---@field kind 'procedure' | 'function'
---@field content string  the DDL/source query that renders this routine's definition

--- The routines under one schema (schema-supporting adapters). Mirrors
--- `DadbodUI.SchemaItem`'s nesting so the drawer renders it the same way.
---@class DadbodUI.RoutineSchemaItem
---@field expanded boolean
---@field list DadbodUI.RoutineItem[]

--- The stored procedures / functions collection for a connection (M-routines).
--- Schema-supporting adapters populate `list`/`items` (schema names -> routines,
--- mirroring `DadbodUI.SchemasNode`); flat adapters (mysql-with-db) populate
--- `flat`. Empty for adapters with no routine support (e.g. sqlite).
---@class DadbodUI.RoutinesNode
---@field expanded boolean
---@field list string[]  schema names that own routines (schema adapters)
---@field items table<string, DadbodUI.RoutineSchemaItem>  per-schema routines (schema adapters)
---@field flat DadbodUI.RoutineItem[]  routines, ungrouped (non-schema adapters)

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
---@field parse_results? fun(results: string[], min_len: integer): any[]
---@field default_scheme? string
---@field quote? integer
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
---@field has_virtual_results? boolean  result columns span screen lines (oracle)
---@field parse_virtual_results? fun(results: string[], min_len: integer): any[]
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
---@field save_name string  group-qualified identifier ({group}_{name} when grouped); names the save folder + tmp buffers
---@field scheme string  raw adapter scheme
---@field db_name string
---@field save_path string
---@field conn? string  live connection handle, set when connected
---@field conn_error? string  last connection error, if any
---@field connect_ms? integer  elapsed ms of the last successful connect (shown in the details view, not a popup)
---@field conn_tried boolean  whether a connection was attempted
---@field loading? boolean  transient: connecting/introspecting (drawer shows the loading icon); cleared on data-land/error
---@field expanded boolean  drawer expand state
---@field schema_support boolean  does the adapter expose schemas
---@field quote boolean  whether the adapter quotes identifiers (used by M8)
---@field default_scheme string  the adapter's default schema name
---@field filetype string  query-buffer filetype for this adapter
---@field extension string  adapter's query-input file extension (names generated buffers so external tooling attaches)
---@field table_helpers table<string, string>  helper name -> SQL template
---@field tables DadbodUI.TablesNode
---@field schemas DadbodUI.SchemasNode
---@field routines DadbodUI.RoutinesNode  stored procedures / functions for this connection
---@field routine_support boolean  does the adapter expose stored procedures/functions
---@field buffers DadbodUI.BuffersNode  open query buffers for this connection
---@field saved_queries DadbodUI.SavedQueriesNode  persisted saved queries

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

--- A drawer tree node; one per rendered line (content[line]).
---@class DadbodUI.Node
---@field label string
---@field icon string
---@field level integer
---@field type string  'group'|'db'|'query'|'schemas'|'tables'|'schema'|'table'|'table_helper'|'routines'|'routine_schema'|'routine'|'buffer'|'saved_query'|'buffers'|'saved_queries'|'dbout'|'dbout_list'|'help'|'add_connection'|...
---@field action string  'toggle'|'open'|'call_method'|'noaction'
---@field key_name? string
---@field group? string
---@field expanded? boolean
---@field toggle_state? { expanded: boolean }  the `{ expanded }` table this node flips on toggle (entry for db, group_state for group, the section sub-node otherwise)
---@field on_expand? fun()  side effect fired once a toggle opens the node (db lazy introspection)
---@field table? string  table name (table / table_helper nodes)
---@field schema? string  schema name (table / table_helper nodes)
---@field content? string  helper SQL template (table_helper nodes)
---@field file_path? string  on-disk path (buffer / saved_query / dbout nodes)
---@field saved? boolean  true for saved-query nodes (vs tmp/open buffers)
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
---@field prefer_native boolean
---@field default_path string  '' => cwd, else a directory
---@field coerce_numbers boolean
---@field csv table
---@field tsv table
---@field json table

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
---@field title? string   override the '[DBUI]' title
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

--- Resolved configuration (dadbod-ui.config).
---@class DadbodUI.Config
---@field save_location string
---@field tmp_query_location string
---@field table_helpers table<string, table<string, string>>
---@field table_helpers_order string[]  display order for a table's helpers
---@field default_query string
---@field execute_on_save boolean
---@field auto_execute_table_helpers boolean
---@field page_size integer  rows per result page (M-pagination LIMIT/OFFSET)
---@field env_variable_url string
---@field env_variable_name string
---@field dotenv_variable_prefix string
---@field disable_progress_bar boolean
---@field notification_width integer
---@field winwidth integer
---@field win_position 'left'|'right'
---@field result_layout 'horizontal'|'vertical'  split direction for the `.dbout` result window
---@field show_help boolean
---@field show_database_icon boolean
---@field use_nerd_fonts boolean
---@field use_postgres_views boolean
---@field hide_schemas string[]
---@field bind_param_pattern string
---@field drawer_sections string[]
---@field expand_groups boolean
---@field dbout_list_sort 'asc'|'desc'
---@field force_echo_notifications boolean
---@field disable_info_notifications boolean
---@field use_nvim_notify boolean
---@field is_oracle_legacy boolean
---@field debug boolean
---@field disable_mappings boolean
---@field disable_mappings_dbui boolean
---@field disable_mappings_dbout boolean
---@field disable_mappings_sql boolean
---@field disable_mappings_javascript boolean
---@field icons table
---@field query_time DadbodUI.QueryTimeConfig
---@field show_buffer_connection boolean  right-aligned `group/name` winbar on query buffers
---@field export DadbodUI.ExportConfig
---@field mappings table<string, table<string, DadbodUI.Mapping>>
---@field buffer_name_generator? DadbodUI.BufferNameGenerator
---@field table_name_sorter? DadbodUI.TableNameSorter
---@field hooks? DadbodUI.Hooks

--- Inline post-execute feedback (time + row count). See `query_time` in the
--- config defaults.
---@class DadbodUI.QueryTimeConfig
---@field enabled boolean  master switch; also gates suppression of dadbod's echoes
---@field result_buffer boolean  virtual line at the top of the `.dbout` buffer
---@field query_buffer boolean  ghost text trailing the executed line in the SQL buffer
---@field show_row_count boolean  append `· N rows` to the summary

--- The most recently executed query and its wall-clock runtime, surfaced by
--- `:DBUILastQueryInfo` and the dbout branch of `statusline`. `last_query_time`
--- is dadbod's `b:db.runtime` (seconds, as a string) recorded when the async
--- result lands, or `''` before any query finished.
---@class DadbodUI.LastQueryInfo
---@field last_query string[]  lines of the most recently executed query
---@field last_query_time string  runtime in seconds ('' before any result)

--- Options for `require('dadbod-ui').statusline()` (the `db_ui#statusline()`
--- opts dict). All optional.
---@class DadbodUI.StatuslineOpts
---@field prefix? string  leading text (default 'DBUI: ')
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
--- around a `:DBUICancelQuery`. Only fired when there is a cancellable async
--- query (gated on `bridge.can_cancel()`).
---@class DadbodUI.CancelEvent
---@field bufnr integer  the query buffer whose running async query is being cancelled

--- Any event passed to a hook -- the union `dadbod-ui.hooks` dispatches over.
---@alias DadbodUI.HookEvent DadbodUI.ConnectEvent|DadbodUI.QueryEvent|DadbodUI.QueryResultEvent|DadbodUI.CancelEvent

--- User-configurable lifecycle hooks (`config.hooks`). Every hook is optional; a
--- missing one is a clean no-op. `on_connect` is a transform: returning a string
--- rewrites the connection url before connecting (the password use case). The
--- rest are observers -- their return value is ignored. A throwing hook is caught
--- and notified, never aborting the underlying connect / execute / cancel.
---@class DadbodUI.Hooks
---@field on_connect? fun(event: DadbodUI.ConnectEvent): string|nil  before connect; return a string to rewrite the url
---@field on_connect_post? fun(event: DadbodUI.ConnectEvent)  after connect (success/error on the event)
---@field on_execute_query? fun(event: DadbodUI.QueryEvent)  before the SQL is dispatched
---@field on_execute_query_post? fun(event: DadbodUI.QueryResultEvent)  after the result lands (read/persist rows)
---@field on_cancel_query? fun(event: DadbodUI.CancelEvent)  before a running query is cancelled
---@field on_cancel_query_post? fun(event: DadbodUI.CancelEvent)  after a running query is cancelled

--- A single configurable keybinding. `key` is a string, a list of strings
--- (aliases), or `'none'` to disable. `mode` (default `'n'`) is the mode(s) it
--- binds in. `binds` is an escape hatch for actions whose lhs differs per mode;
--- when present it is the authoritative bind list while `key` drives help text.
---@class DadbodUI.Mapping
---@field key string|string[]  the lhs, or 'none' to disable
---@field desc string  one-line description shown in the help window
---@field mode? string|string[]  default 'n'
---@field binds? { mode: string, lhs: string }[]
