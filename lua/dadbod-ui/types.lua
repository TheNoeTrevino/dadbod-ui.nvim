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

--- A tables collection (the original's `{ expanded, list, items }`).
---@class DadbodUI.TablesNode
---@field expanded boolean
---@field list string[]
---@field items table<string, DadbodUI.TableItem>

--- A single schema and the tables under it.
---@class DadbodUI.SchemaItem
---@field expanded boolean
---@field tables DadbodUI.TablesNode

--- The schemas collection for a connection.
---@class DadbodUI.SchemasNode
---@field expanded boolean
---@field list string[]
---@field items table<string, DadbodUI.SchemaItem>

--- Per-adapter introspection metadata (dadbod-ui.schemas). Mirrors the original
--- `s:schemas[scheme]` dict; M6 uses the schema/table listing fields, later
--- milestones use the foreign-key / select fields.
---@class DadbodUI.SchemaAdapter
---@field args? string[]              extra argv appended to the adapter command
---@field schemes_query? string       SQL listing schema names
---@field schemes_tables_query? string  SQL listing (schema, table) pairs
---@field parse_results? fun(results: string[], min_len: integer): any[]
---@field default_scheme? string
---@field quote? integer
---@field filetype? string
---@field requires_stdin? boolean
---@field callable? string            'interactive' (default) | 'filter'

--- Per-connection state entry held by the instance.
---@class DadbodUI.ConnectionEntry
---@field url string
---@field source DadbodUI.Source
---@field name string
---@field group string
---@field key_name string
---@field scheme string  raw adapter scheme
---@field db_name string
---@field save_path string
---@field conn? string  live connection handle, set when connected
---@field conn_error? string  last connection error, if any
---@field conn_tried boolean  whether a connection was attempted
---@field expanded boolean  drawer expand state
---@field schema_support boolean  does the adapter expose schemas
---@field quote boolean  whether the adapter quotes identifiers (used by M8)
---@field default_scheme string  the adapter's default schema name
---@field filetype string  query-buffer filetype for this adapter
---@field table_helpers table<string, string>  helper name -> SQL template
---@field tables DadbodUI.TablesNode
---@field schemas DadbodUI.SchemasNode

--- Public connection summary (connections_list()).
---@class DadbodUI.ConnectionInfo
---@field name string
---@field url string
---@field is_connected boolean
---@field source DadbodUI.Source

--- A drawer tree node; one per rendered line (content[line]).
---@class DadbodUI.Node
---@field label string
---@field icon string
---@field level integer
---@field type string  'group'|'db'|'query'|'schemas'|'tables'|'schema'|'table'|'table_helper'|'help'|'add_connection'|...
---@field action string  'toggle'|'open'|'call_method'|'noaction'
---@field key_name? string
---@field group? string
---@field expanded? boolean
---@field toggle_state? { expanded: boolean }  node whose `expanded` flips on toggle
---@field table? string  table name (table / table_helper nodes)
---@field schema? string  schema name (table / table_helper nodes)
---@field content? string  helper SQL template (table_helper nodes)

--- A command spec for the bridge concurrency helpers.
---@class DadbodUI.CommandSpec
---@field cmd string[]
---@field stdin? string

--- Payload passed to on_pre/on_post subscribers.
---@class DadbodUI.ExecuteEvent
---@field output_file string
---@field match string

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
---@field default_query string
---@field execute_on_save boolean
---@field auto_execute_table_helpers boolean
---@field env_variable_url string
---@field env_variable_name string
---@field dotenv_variable_prefix string
---@field disable_progress_bar boolean
---@field notification_width integer
---@field winwidth integer
---@field win_position 'left'|'right'
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
---@field buffer_name_generator? DadbodUI.BufferNameGenerator
---@field table_name_sorter? DadbodUI.TableNameSorter
