---@mod dadbod-ui.export_formats  Pure result formatters over the canonical export data
---
--- Turns a `DadbodUI.ExportData` (faithful, string-typed rows parsed from a CLI's
--- delimited output -- see `dadbod-ui.export_extract`) into a serialized document
--- in a target format. Every function here is PURE: `(data, opts) -> string`, no
--- Neovim buffers and no database, so the whole module is exhaustively unit-tested
--- against the fixtures in `specs/native-export.md` §5.
---
--- These are reimplementations (not copies) of DBeaver's stream exporters
--- (`DataExporterCSV/JSON/MarkdownTable/HTML/XML`), pared down to the options that
--- matter for a terminal workflow.
---
--- SQL NULL is the module sentinel `M.NULL`, never a Lua nil -- Lua arrays cannot
--- hold nil holes, and we must distinguish a real NULL from an empty string.

local M = {}

--- The SQL-NULL sentinel carried in `ExportData` rows. Compare cells with
--- `cell == M.NULL`; it is a unique table so it can never collide with a value.
M.NULL = setmetatable({}, {
  __tostring = function()
    return 'NULL'
  end,
})

---@param v any
---@return boolean
local function is_null(v)
  return v == M.NULL
end

--- Whether `s` may be emitted as a bare JSON/SQL numeric or boolean literal under
--- `coerce_numbers`. Strict on purpose: a plain boolean, or a number with no
--- leading zeros, no leading/trailing dot, and no exponent -- so `007`, `1.`,
--- `.5`, `1e5`, `+1` stay quoted strings rather than becoming invalid literals.
---@param s string
---@return boolean
local function coercible(s)
  if s == 'true' or s == 'false' then
    return true
  end
  return s:match('^%-?0$') ~= nil
    or s:match('^%-?[1-9]%d*$') ~= nil
    or s:match('^%-?0%.%d+$') ~= nil
    or s:match('^%-?[1-9]%d*%.%d+$') ~= nil
end

-- CSV / TSV ------------------------------------------------------------------

--- A field needs quoting when it contains the delimiter, the quote char, or a
--- line break (CR/LF) -- the RFC-4180 quoting triggers.
---@param value string
---@param delimiter string
---@param quote string
---@return boolean
local function needs_quote(value, delimiter, quote)
  return value:find(delimiter, 1, true) ~= nil
    or value:find(quote, 1, true) ~= nil
    or value:find('\n', 1, true) ~= nil
    or value:find('\r', 1, true) ~= nil
end

--- Render one already-stringified field. With quoting enabled (a non-empty
--- `quote`), RFC-4180 rules apply: quote when needed, escaping the quote char by
--- doubling. With quoting disabled (TSV), embedded newlines collapse to
--- `line_feed_escape` and an embedded delimiter collapses to `escape_delimiter`
--- so the columns stay aligned without quotes.
---@param value string
---@param opts table  resolved csv opts
---@return string
local function csv_field(value, opts)
  if opts.line_feed_escape ~= nil and opts.line_feed_escape ~= '' then
    value = value:gsub('\r\n', '\n'):gsub('[\r\n]', opts.line_feed_escape)
  end
  local quoting = opts.quote ~= nil and opts.quote ~= ''
  if not quoting then
    if opts.escape_delimiter ~= nil and value:find(opts.delimiter, 1, true) then
      value = value:gsub(vim.pesc(opts.delimiter), opts.escape_delimiter)
    end
    return value
  end
  local q = opts.quote
  if needs_quote(value, opts.delimiter, q) then
    return q .. value:gsub(vim.pesc(q), q .. q) .. q
  end
  return value
end

--- Join one row (header or data) into a delimited line. Header cells are plain
--- strings; data cells may be the NULL sentinel, rendered as `null_string`.
---@param cells any[]
---@param opts table
---@param is_data boolean
---@return string
local function csv_row(cells, opts, is_data)
  local out = {}
  for i, cell in ipairs(cells) do
    if is_data and is_null(cell) then
      out[i] = opts.null_string or ''
    else
      out[i] = csv_field(tostring(cell), opts)
    end
  end
  return table.concat(out, opts.delimiter)
end

--- Resolve csv opts over the defaults. `header` defaults true; `quote` defaults
--- `"`; `null_string` empty; `line_feed_escape` empty (so embedded newlines stay
--- and trigger quoting).
---@param opts? table
---@return table
local function csv_opts(opts)
  opts = opts or {}
  return {
    delimiter = opts.delimiter or ',',
    header = opts.header ~= false,
    quote = opts.quote == nil and '"' or opts.quote,
    null_string = opts.null_string or '',
    line_feed_escape = opts.line_feed_escape or '',
    escape_delimiter = opts.escape_delimiter,
  }
end

--- CSV document for `data`. Port of `DataExporterCSV`'s core: per-field RFC-4180
--- quoting with doubled quote escaping, optional header, configurable delimiter /
--- quote / null marker.
---@param data DadbodUI.ExportData
---@param opts? table  { delimiter, header, quote, null_string, line_feed_escape }
---@return string
function M.csv(data, opts)
  opts = csv_opts(opts)
  local lines = {}
  if opts.header then
    lines[#lines + 1] = csv_row(data.columns, opts, false)
  end
  for _, row in ipairs(data.rows) do
    lines[#lines + 1] = csv_row(row, opts, true)
  end
  return table.concat(lines, '\n')
end

--- TSV document: tab-separated, quoting disabled, embedded newlines/tabs escaped
--- to their literals so columns stay aligned (matching mysql `--batch` framing).
---@param data DadbodUI.ExportData
---@param opts? table  { header, null_string, line_feed_escape }
---@return string
function M.tsv(data, opts)
  opts = opts or {}
  return M.csv(data, {
    delimiter = '\t',
    header = opts.header ~= false,
    quote = '',
    null_string = opts.null_string or '',
    line_feed_escape = opts.line_feed_escape or '\\n',
    escape_delimiter = '\\t',
  })
end

-- JSON -----------------------------------------------------------------------

--- Escape a string for a JSON double-quoted literal: backslash first, then quote
--- and the common control chars, then any remaining C0 control as `\u00xx`.
---@param s string
---@return string
local function json_escape(s)
  s = s:gsub('\\', '\\\\'):gsub('"', '\\"')
  s = s:gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
  s = s:gsub('[%z\1-\31]', function(c)
    return string.format('\\u%04x', c:byte())
  end)
  return s
end

--- A cell as a JSON value: NULL -> `null`; with `coerce_numbers`, a numeric or
--- boolean-looking string is emitted bare; otherwise a quoted, escaped string.
---@param cell any
---@param opts table
---@return string
local function json_value(cell, opts)
  if is_null(cell) then
    return 'null'
  end
  local s = tostring(cell)
  if opts.coerce_numbers and coercible(s) then
    return s
  end
  return '"' .. json_escape(s) .. '"'
end

--- JSON document for `data`. Port of `DataExporterJSON`: an array of one object
--- per row keyed by column name. `wrap_table_name` (default true) wraps the array
--- in `{ "<source>": [...] }`. `coerce_numbers` (default false) emits
--- numeric/boolean strings unquoted (the CSV extract is untyped -- LIMITATION-002).
---@param data DadbodUI.ExportData
---@param opts? table  { wrap_table_name, indent, coerce_numbers }
---@return string
function M.json(data, opts)
  opts = opts or {}
  local indent = opts.indent or '\t'
  local wrap = opts.wrap_table_name ~= false
  local objs = {}
  for _, row in ipairs(data.rows) do
    local fields = {}
    for i, col in ipairs(data.columns) do
      fields[i] = indent .. indent .. '"' .. json_escape(col) .. '" : ' .. json_value(row[i], opts)
    end
    objs[#objs + 1] = indent .. '{\n' .. table.concat(fields, ',\n') .. '\n' .. indent .. '}'
  end
  local array = #objs == 0 and '[]' or ('[\n' .. table.concat(objs, ',\n') .. '\n]')
  if wrap then
    return '{\n"' .. json_escape(data.source or '') .. '": ' .. array .. '}'
  end
  return array
end

-- Markdown -------------------------------------------------------------------

--- A cell for a GitHub Markdown table: NULL -> empty; pipes escaped as `\|`;
--- newlines collapsed to `<br>` so the cell stays on one table row.
---@param cell any
---@return string
local function md_cell(cell)
  if is_null(cell) then
    return ''
  end
  return (tostring(cell):gsub('|', '\\|'):gsub('\r\n', '\n'):gsub('\n', '<br>'))
end

--- Markdown table for `data`. Port of `DataExporterMarkdownTable`: a header row,
--- a `---` delimiter row, then one row per record, each cell padded by a space.
---@param data DadbodUI.ExportData
---@return string
function M.markdown(data)
  local function pipe(cells)
    return '| ' .. table.concat(cells, ' | ') .. ' |'
  end
  local lines = {}
  lines[#lines + 1] = pipe(vim.tbl_map(md_cell, data.columns))
  local rule = {}
  for i = 1, #data.columns do
    rule[i] = '---'
  end
  lines[#lines + 1] = pipe(rule)
  for _, row in ipairs(data.rows) do
    lines[#lines + 1] = pipe(vim.tbl_map(md_cell, row))
  end
  return table.concat(lines, '\n')
end

-- HTML -----------------------------------------------------------------------

--- Escape text for HTML element content / attribute values.
---@param s string
---@return string
local function html_escape(s)
  return (s:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;'))
end

--- HTML `<table>` for `data` (port of `DataExporterHTML`, minimal/no inline CSS).
--- `<thead>`/`<tbody>`; `&<>"` escaped; NULL -> empty `<td>`; newlines -> `<br>`
--- (OQ-2 decision).
---@param data DadbodUI.ExportData
---@return string
function M.html(data)
  local function cell(c)
    if is_null(c) then
      return ''
    end
    return (html_escape(tostring(c)):gsub('\r\n', '\n'):gsub('\n', '<br>'))
  end
  local lines = { '<table>', '<thead>' }
  local th = {}
  for _, c in ipairs(data.columns) do
    th[#th + 1] = '<th>' .. html_escape(c) .. '</th>'
  end
  lines[#lines + 1] = '<tr>' .. table.concat(th) .. '</tr>'
  lines[#lines + 1] = '</thead>'
  lines[#lines + 1] = '<tbody>'
  for _, row in ipairs(data.rows) do
    local td = {}
    for i = 1, #data.columns do
      td[#td + 1] = '<td>' .. cell(row[i]) .. '</td>'
    end
    lines[#lines + 1] = '<tr>' .. table.concat(td) .. '</tr>'
  end
  lines[#lines + 1] = '</tbody>'
  lines[#lines + 1] = '</table>'
  return table.concat(lines, '\n')
end

-- XML ------------------------------------------------------------------------

--- Escape text for XML content / attribute values (adds `'` over HTML).
---@param s string
---@return string
local function xml_escape(s)
  return (html_escape(s):gsub("'", '&apos;'))
end

--- XML document for `data` (port of `DataExporterXML`, OQ-2 shape): a `<data>`
--- root, one `<row>` per record, one `<col name="...">value</col>` per column.
--- NULL -> self-closing `<col name="..." isNull="true"/>`.
---@param data DadbodUI.ExportData
---@return string
function M.xml(data)
  local lines = { '<?xml version="1.0" encoding="UTF-8"?>', '<data>' }
  for _, row in ipairs(data.rows) do
    lines[#lines + 1] = '  <row>'
    for i, col in ipairs(data.columns) do
      local c = row[i]
      if is_null(c) then
        lines[#lines + 1] = string.format('    <col name="%s" isNull="true"/>', xml_escape(col))
      else
        lines[#lines + 1] = string.format('    <col name="%s">%s</col>', xml_escape(col), xml_escape(tostring(c)))
      end
    end
    lines[#lines + 1] = '  </row>'
  end
  lines[#lines + 1] = '</data>'
  return table.concat(lines, '\n')
end

-- SQL INSERT -----------------------------------------------------------------

--- A cell as a SQL literal: NULL -> bare `NULL`; with `coerce_numbers`, a
--- numeric/boolean-looking string is emitted bare; otherwise a single-quoted
--- string with `'` doubled.
---@param cell any
---@param opts table
---@return string
local function sql_value(cell, opts)
  if is_null(cell) then
    return 'NULL'
  end
  local s = tostring(cell)
  if opts.coerce_numbers and coercible(s) then
    return s
  end
  return "'" .. s:gsub("'", "''") .. "'"
end

--- SQL `INSERT` statements for `data`, one per row. Port of `DataExporterSQL`.
--- Target table: `opts.table` else `data.source` else `exported_table`.
--- `quote_identifiers` wraps table/column names in `identifier_quote` (`"` by
--- default) -- driven by the adapter's `quote` flag at the call site.
---@param data DadbodUI.ExportData
---@param opts? table  { table, quote_identifiers, identifier_quote, coerce_numbers }
---@return string
function M.sql(data, opts)
  opts = opts or {}
  local tbl = opts.table or data.source or 'exported_table'
  local q = opts.quote_identifiers and (opts.identifier_quote or '"') or ''
  local function ident(name)
    return q .. name .. q
  end
  local cols = {}
  for i, c in ipairs(data.columns) do
    cols[i] = ident(c)
  end
  local col_list = table.concat(cols, ', ')
  local lines = {}
  for _, row in ipairs(data.rows) do
    local vals = {}
    for i = 1, #data.columns do
      vals[i] = sql_value(row[i], opts)
    end
    lines[#lines + 1] =
      string.format('INSERT INTO %s (%s) VALUES (%s);', ident(tbl), col_list, table.concat(vals, ', '))
  end
  return table.concat(lines, '\n')
end

return M
