-- Pure result formatters over the canonical export data
--
-- Turns a `DadbodUI.ExportData` (faithful, string-typed rows parsed from a CLI's
-- delimited output -- see `dadbod-ui.export.extract`) into a serialized document
-- in a target format. Every function here is PURE: `(data, opts) -> string`, no
-- Neovim buffers and no database, so the whole module is exhaustively unit-tested
-- against the fixtures in `specs/native-export.md` §5.
--
-- Each function is a pure formatter that serializes a result set to one target
-- format (CSV, TSV, JSON, Markdown, HTML, XML, SQL), exposing the options that
-- matter for a terminal workflow.
--
-- SQL NULL is the module sentinel `M.NULL`, never a Lua nil -- Lua arrays cannot
-- hold nil holes, and we must distinguish a real NULL from an empty string.

---@class DadbodUI.ExportFormatsModule
---@field NULL table  the SQL-NULL sentinel carried in `ExportData` rows
---@field csv fun(data: DadbodUI.ExportData, opts?: table): string
---@field tsv fun(data: DadbodUI.ExportData, opts?: table): string
---@field json fun(data: DadbodUI.ExportData, opts?: table): string
---@field markdown fun(data: DadbodUI.ExportData): string
---@field html fun(data: DadbodUI.ExportData): string
---@field xml fun(data: DadbodUI.ExportData): string
---@field sql fun(data: DadbodUI.ExportData, opts?: table): string
---@field nonempty fun(s: any): string?

---@type DadbodUI.ExportFormatsModule
---@diagnostic disable-next-line: missing-fields
local M = {}

--- The SQL-NULL sentinel carried in `ExportData` rows. Compare cells with
--- `cell == M.NULL`; it is a unique table so it can never collide with a value.
M.NULL = setmetatable({}, {
  __tostring = function()
    return 'NULL'
  end,
})

---@private
---@param v any
---@return boolean
local function is_null(v)
  return v == M.NULL
end

---@private
-- Lua-pattern-escape `s` (like `vim.pesc`) and `map(fn, list)` (like
-- `vim.tbl_map`), reimplemented with only stdlib so this module stays free of the
-- `vim` API -- it must load and run inside a `vim.uv` worker thread (see
-- `dadbod-ui.export`.\_transform_async), which has no `vim` global.
---@param s string
---@return string
local function pesc(s)
  return (s:gsub('[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%1'))
end

---@private
---@param fn fun(v: any): any
---@param list any[]
---@return any[]
local function map(fn, list)
  local out = {}
  for i = 1, #list do
    out[i] = fn(list[i])
  end
  return out
end

---@private
-- Escape `%` in a string so it is safe to pass as a `gsub` REPLACEMENT (as
-- opposed to `pesc`, which escapes a string for use as the PATTERN). Every
-- user-configured replacement (`line_feed_escape`, `escape_delimiter`) must go
-- through this before reaching `gsub`, else a value containing `%` raises
-- "invalid use of '%' in replacement string" (or, worse, silently consumes a
-- capture reference like `%1`).
---@param s string
---@return string
local function repl_esc(s)
  return (s:gsub('%%', '%%%%'))
end

-- Empty-string-safe truthiness: '' is truthy in Lua, which would otherwise
-- defeat an `a or b` fallback chain (e.g. `opts.table or data.source or
-- 'exported_table'`) when the empty string is passed explicitly. Exposed on `M`
-- so the (vim-free) transform paths in `export.lua` share this one definition
-- rather than re-inlining the check.
---@param s any
---@return string?
function M.nonempty(s)
  return (type(s) == 'string' and s ~= '') and s or nil
end
local nonempty = M.nonempty

---@private
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

---@private
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

---@private
--- Render one already-stringified field. With quoting enabled (a non-empty
--- `quote`), RFC-4180 rules apply: quote when needed, escaping the quote char by
--- doubling. With quoting disabled (TSV), a literal backslash is escaped FIRST
--- (matching mysql `--batch` framing), THEN embedded newlines collapse to
--- `line_feed_escape` and an embedded delimiter collapses to `escape_delimiter`
--- so the columns stay aligned without quotes -- escaping backslash first keeps
--- a real `\t`/`\n` two-char sequence in the data from colliding with an escaped
--- real tab/newline.
---@param value string
---@param opts table  resolved csv opts
---@return string
local function csv_field(value, opts)
  local quoting = opts.quote ~= nil and opts.quote ~= ''
  if not quoting then
    if (opts.line_feed_escape ~= nil and opts.line_feed_escape ~= '') or opts.escape_delimiter ~= nil then
      value = value:gsub('\\', '\\\\')
    end
    if opts.line_feed_escape ~= nil and opts.line_feed_escape ~= '' then
      value = value:gsub('\r\n', '\n'):gsub('[\r\n]', repl_esc(opts.line_feed_escape))
    end
    if opts.escape_delimiter ~= nil and value:find(opts.delimiter, 1, true) then
      value = value:gsub(pesc(opts.delimiter), repl_esc(opts.escape_delimiter))
    end
    return value
  end
  if opts.line_feed_escape ~= nil and opts.line_feed_escape ~= '' then
    value = value:gsub('\r\n', '\n'):gsub('[\r\n]', repl_esc(opts.line_feed_escape))
  end
  local q = opts.quote
  if needs_quote(value, opts.delimiter, q) then
    return q .. value:gsub(pesc(q), q .. q) .. q
  end
  return value
end

---@private
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

---@private
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

--- CSV document for `data`: per-field RFC-4180 quoting with doubled quote
--- escaping, optional header, configurable delimiter / quote / null marker.
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

---@private
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

---@private
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

--- JSON document for `data`: an array of one object
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

---@private
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

--- Markdown table for `data`: a header row, a `---` delimiter row, then one row
--- per record, each cell padded by a space.
---@param data DadbodUI.ExportData
---@return string
function M.markdown(data)
  local function pipe(cells)
    return '| ' .. table.concat(cells, ' | ') .. ' |'
  end
  local lines = {}
  lines[#lines + 1] = pipe(map(md_cell, data.columns))
  local rule = {}
  for i = 1, #data.columns do
    rule[i] = '---'
  end
  lines[#lines + 1] = pipe(rule)
  for _, row in ipairs(data.rows) do
    lines[#lines + 1] = pipe(map(md_cell, row))
  end
  return table.concat(lines, '\n')
end

-- HTML -----------------------------------------------------------------------

---@private
--- Escape text for HTML element content / attribute values.
---@param s string
---@return string
local function html_escape(s)
  return (s:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;'))
end

--- HTML `<table>` for `data` (minimal/no inline CSS). `<thead>`/`<tbody>`; `&<>"`
--- escaped; NULL -> empty `<td>`; newlines -> `<br>` (OQ-2 decision).
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

---@private
--- Escape text for XML content / attribute values (adds `'` over HTML).
---@param s string
---@return string
local function xml_escape(s)
  return (html_escape(s):gsub("'", '&apos;'))
end

--- XML document for `data` (OQ-2 shape): a `<data>`
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

---@private
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

--- SQL `INSERT` statements for `data`, one per row.
--- Target table: `opts.table` else `data.source` else `exported_table`.
--- `quote_identifiers` wraps table/column names in `identifier_quote` (`"` by
--- default) -- driven by the adapter's `quote` flag at the call site.
---@param data DadbodUI.ExportData
---@param opts? table  { table, quote_identifiers, identifier_quote, coerce_numbers }
---@return string
function M.sql(data, opts)
  opts = opts or {}
  local tbl = nonempty(opts.table) or nonempty(data.source) or 'exported_table'
  local q = opts.quote_identifiers and (opts.identifier_quote or '"') or ''
  -- `q` is symmetric (opened AND closed with the same delimiter, e.g. `"`/`` ` ``),
  -- so an identifier containing that char must have it doubled to stay balanced --
  -- otherwise a column named `a"b` would emit `"a"b"`, a broken/truncated literal.
  local function ident(name)
    if q == '' then
      return name
    end
    return q .. (name:gsub(pesc(q), repl_esc(q .. q))) .. q
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
