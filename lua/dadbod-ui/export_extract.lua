---@mod dadbod-ui.export_extract  Parse a CLI's delimited output into ExportData
---
--- The canonical extractor (`specs/native-export.md` §3): the database CLI is run
--- in a native delimited mode and its stdout is parsed here into a faithful
--- `DadbodUI.ExportData` (the first row is the header). PURE: string in, table out,
--- no Neovim/DB -- so the (fiddly) CSV/TSV parsing is exhaustively unit-tested.
---
---   * `from_csv` -- RFC-4180: quoted fields, embedded delimiters/CR/LF, doubled
---     quotes. Used for psql `--csv` and sqlite `-csv -header`. These CLIs render
---     SQL NULL as an empty field, indistinguishable from `''` (LIMITATION-001),
---     so an empty field parses to `''`, never the NULL sentinel.
---   * `from_tsv` -- mysql `--batch`: tab-separated with backslash escapes and a
---     literal `\N` for SQL NULL, so NULLs ARE recovered here (mapped to the
---     `export_formats.NULL` sentinel).

local formats = require('dadbod-ui.export_formats')

local M = {}

-- CSV (RFC-4180) -------------------------------------------------------------

--- Parse RFC-4180 CSV `text` into a list of row arrays (each a list of string
--- fields). Handles quoted fields containing the delimiter, CR/LF, and doubled
--- quote escapes. A trailing record separator does not yield a spurious empty row.
---@param text string
---@param delimiter string
---@param quote string
---@return string[][]
local function parse_csv(text, delimiter, quote)
  local rows = {}
  local row = {}
  local field = {}
  local in_quotes = false
  -- Tracks whether the current row has any pending field content. Needed because
  -- a lone trailing `""` empty quoted field must still emit one field.
  local row_dirty = false
  local i, n = 1, #text

  local function end_field()
    row[#row + 1] = table.concat(field)
    field = {}
  end
  local function end_row()
    end_field()
    rows[#rows + 1] = row
    row = {}
    row_dirty = false
  end

  -- CSV can't use the cheap `gsub('\r?\n$','')` trailing-newline strip that
  -- from_tsv uses: under RFC-4180 a trailing newline may sit inside a quoted
  -- field, so we must track row state and flush only a genuinely dirty row.
  while i <= n do
    local c = text:sub(i, i)
    if in_quotes then
      if c == quote then
        if text:sub(i + 1, i + 1) == quote then
          field[#field + 1] = quote
          i = i + 2
        else
          in_quotes = false
          i = i + 1
        end
      else
        field[#field + 1] = c
        i = i + 1
      end
    elseif c == quote then
      in_quotes = true
      row_dirty = true
      i = i + 1
    elseif c == delimiter then
      end_field()
      row_dirty = true
      i = i + 1
    elseif c == '\n' then
      end_row()
      i = i + 1
    elseif c == '\r' then
      i = (text:sub(i + 1, i + 1) == '\n') and i + 2 or i + 1
      end_row()
    else
      field[#field + 1] = c
      row_dirty = true
      i = i + 1
    end
  end
  if row_dirty then
    end_field()
    rows[#rows + 1] = row
  end
  return rows
end

--- Turn a list of parsed row-arrays into `ExportData`: the first row becomes the
--- column header, the rest the data rows. `null_marker` (when given) maps a field
--- equal to it to the NULL sentinel. Empty input yields empty columns/rows.
---@param raw string[][]
---@param null_marker? string
---@return DadbodUI.ExportData
local function to_export_data(raw, null_marker)
  if #raw == 0 then
    return { columns = {}, rows = {} }
  end
  local columns = raw[1]
  local rows = {}
  for r = 2, #raw do
    local src = raw[r]
    local out = {}
    for c = 1, #columns do
      local v = src[c]
      if v == nil then
        out[c] = ''
      elseif null_marker ~= nil and v == null_marker then
        out[c] = formats.NULL
      else
        out[c] = v
      end
    end
    rows[#rows + 1] = out
  end
  return { columns = columns, rows = rows }
end

--- Parse CSV (psql `--csv` / sqlite `-csv -header`) into `ExportData`. NULL is
--- indistinguishable from empty here (LIMITATION-001): an empty field stays `''`.
---@param text string
---@param opts? { delimiter?: string, quote?: string }
---@return DadbodUI.ExportData
function M.from_csv(text, opts)
  opts = opts or {}
  local raw = parse_csv(text, opts.delimiter or ',', opts.quote or '"')
  return to_export_data(raw)
end

-- TSV (mysql --batch) --------------------------------------------------------

local TSV_UNESCAPE = { t = '\t', n = '\n', r = '\r', ['0'] = '\0', ['\\'] = '\\' }

--- Unescape one mysql `--batch` field: `\t \n \r \0 \\` map to their characters,
--- any other `\x` drops the backslash. (A whole-field `\N` is handled before this
--- as SQL NULL.)
---@param field string
---@return string
local function tsv_unescape(field)
  return (field:gsub('\\(.)', function(e)
    return TSV_UNESCAPE[e] or e
  end))
end

--- Parse mysql `--batch` TSV `text` into `ExportData`. Rows are newline-separated
--- (value newlines are escaped to `\n`), fields tab-separated, and a field that is
--- exactly `\N` (Oracle's mysql client) OR the literal `NULL` (MariaDB's client,
--- which renders SQL NULL that way under `--batch`) is SQL NULL, mapped to the
--- sentinel. A real string value of `\N`/`NULL` is therefore indistinguishable
--- from SQL NULL (LIMITATION-003) -- the same empty-vs-NULL ambiguity class as the
--- CSV extract (LIMITATION-001), and it is client-dependent which marker appears.
---@param text string
---@param opts? { header?: boolean }
---@return DadbodUI.ExportData
function M.from_tsv(text, opts)
  opts = opts or {}
  -- Drop a single trailing newline so the last row isn't a spurious empty record.
  text = text:gsub('\r?\n$', '')
  if text == '' then
    return { columns = {}, rows = {} }
  end
  local lines = vim.split(text, '\n', { plain = true })
  local raw = {}
  for r, line in ipairs(lines) do
    local fields = vim.split(line, '\t', { plain = true })
    local out = {}
    for i, f in ipairs(fields) do
      -- Map a whole-field NULL marker to the sentinel in DATA rows only (r > 1);
      -- the header row is column names, where a literal `NULL` stays a name.
      if r > 1 and (f == '\\N' or f == 'NULL') then
        out[i] = formats.NULL
      else
        out[i] = tsv_unescape(f)
      end
    end
    raw[r] = out
  end
  return to_export_data(raw)
end

-- Dispatch -------------------------------------------------------------------

--- Parse a CLI's canonical output for `scheme` into `ExportData`: mysql/mariadb
--- use the TSV path (real `\N` NULLs), everything else the CSV path.
---@param scheme string  raw adapter scheme
---@param text string
---@return DadbodUI.ExportData
function M.parse(scheme, text)
  local s = (scheme or ''):lower()
  if s:match('^mysql') or s:match('^mariadb') then
    return M.from_tsv(text)
  end
  return M.from_csv(text)
end

return M
