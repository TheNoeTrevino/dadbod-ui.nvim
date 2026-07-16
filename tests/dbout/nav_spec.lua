-- Specs for dbout folding + cell/foreign-key navigation (M10). The fold heuristic,
-- cell-range arithmetic, header CSV extraction, and the foreign-key SELECT
-- substitution are pure and tested without a buffer. The end-to-end foreign-key
-- jump is guarded on a real postgres adapter (pending when unavailable).

local dbout = require('dadbod-ui.dbout')
local schemas = require('dadbod-ui.schemas')

describe('dbout.foldexpr_for', function()
  it('opens a fold on a mysql `+---` header border', function()
    local lines = { '+----+------+', '| id | name |', '+----+------+', '| 1  | ada  |', '+----+------+' }
    assert.equals('>1', dbout.foldexpr_for(lines, 1))
    -- the data row inside the block stays at level 1
    assert.equals(1, dbout.foldexpr_for(lines, 4))
  end)

  it('opens a fold on a postgres/sqlserver `----` underline (next line)', function()
    local lines = { ' id | name ', '----+------', ' 1  | ada' }
    assert.equals('>1', dbout.foldexpr_for(lines, 1))
    assert.equals(1, dbout.foldexpr_for(lines, 2))
    assert.equals(1, dbout.foldexpr_for(lines, 3))
  end)

  it('closes the fold on a blank line preceding the next result underline', function()
    local lines = { ' id ', '----', ' 1', '', ' id ', '----', ' 2' }
    assert.equals(0, dbout.foldexpr_for(lines, 4))
  end)

  it('keeps a blank line inside the fold when no underline follows it', function()
    local lines = { ' 1', '', ' 2' }
    assert.equals(1, dbout.foldexpr_for(lines, 2))
  end)
end)

describe('dbout.cell_range', function()
  -- separator line: two columns of dashes joined by a `+`
  local sep = '----+------'

  it('spans the run of dashes around the cursor column (first column)', function()
    local r = dbout.cell_range(sep, 1)
    assert.equals(0, r.from)
    assert.equals(3, r.to)
  end)

  it('spans the second column', function()
    local r = dbout.cell_range(sep, 7)
    assert.equals(5, r.from)
    assert.equals(10, r.to)
  end)
end)

describe('dbout.display_span_to_byte_span', function()
  local cells = require('dadbod-ui.dbout.cells')

  it('is a byte-identity for pure-ASCII lines', function()
    local r = cells.display_span_to_byte_span(' id | name ', 5, 10)
    assert.equals(5, r.from)
    assert.equals(10, r.to)
  end)

  it('shifts byte offsets past a multibyte cell (é)', function()
    -- ' héllo | 42 ': the id column occupies DISPLAY cols 8..11, but 'é' is a
    -- 2-byte char, so those map to BYTE offsets 9..12 on the data line.
    local line = ' héllo | 42 '
    local r = cells.display_span_to_byte_span(line, 8, 11)
    assert.equals(9, r.from)
    assert.equals(12, r.to)
    assert.equals('42', vim.trim(line:sub(r.from + 1, r.to + 1)))
  end)

  it('handles double-width (CJK) earlier cells', function()
    -- ' 世 | 42 ': '世' spans display cols 1..2 (3 bytes); the id column at
    -- display cols 5..8 maps to byte offsets 6..9.
    local line = ' 世 | 42 '
    local r = cells.display_span_to_byte_span(line, 5, 8)
    assert.equals('42', vim.trim(line:sub(r.from + 1, r.to + 1)))
    -- a boundary landing on the wide char still yields the whole char
    local n = cells.display_span_to_byte_span(line, 0, 3)
    assert.equals('世', vim.trim(line:sub(n.from + 1, n.to + 1)))
  end)

  it('returns an empty span past the end of a short line', function()
    local r = cells.display_span_to_byte_span('ab', 5, 8)
    assert.is_true(r.to < r.from)
  end)
end)

describe('dbout cell extraction (multibyte alignment)', function()
  local cells = require('dadbod-ui.dbout.cells')

  -- Faithful psql-style block: an earlier cell holds multibyte text, so the
  -- separator line (ASCII) and the header/data lines (multibyte) disagree on
  -- byte offsets. This exercises the shared math behind get_cell_value's range
  -- and jump_to_foreign_table's field_name/field_value extraction.
  local header = ' name  | id '
  local sep = '-------+----'
  local data = ' héllo | 42 '

  -- cursor byte column (0-based) of the '4' in the id cell
  local cursor_byte = 10
  local cursor_col = vim.fn.strdisplaywidth(data:sub(1, cursor_byte))
  local span = cells.cell_range(sep, cursor_col)

  it('extracts the exact later value despite an earlier é cell', function()
    local r = cells.display_span_to_byte_span(data, span.from, span.to)
    assert.equals('42', vim.trim(data:sub(r.from + 1, r.to + 1)))
  end)

  it('extracts the exact header name for the same cell', function()
    local r = cells.display_span_to_byte_span(header, span.from, span.to)
    assert.equals('id', vim.trim(header:sub(r.from + 1, r.to + 1)))
  end)

  it('yields the trimmed byte bounds get_cell_value selects', function()
    -- mirror get_cell_value: map the display span to byte offsets, then trim the
    -- surrounding padding to the byte offsets fed to nvim_win_set_cursor.
    local r = cells.display_span_to_byte_span(data, span.from, span.to)
    local value = data:sub(r.from + 1, r.to + 1)
    local from = r.from + #(value:match('^%s*') or '')
    local to = r.to - #(value:match('%s*$') or '')
    -- the '4' and '2' sit at byte offsets 10 and 11 on the é-shifted data line
    assert.equals(10, from)
    assert.equals(11, to)
    assert.equals('42', data:sub(from + 1, to + 1))
  end)

  it('extracts the exact later value with a double-width (CJK) earlier cell', function()
    -- '世界' is width-4 / 6-byte; the id column's display span maps past it.
    local cjk_header = ' 名   | id '
    local cjk_sep = '------+----'
    local cjk_data = ' 世界 | 99 '
    local cur = vim.fn.strdisplaywidth(cjk_data:sub(1, (assert(cjk_data:find('9', 1, true)) - 1)))
    local s = cells.cell_range(cjk_sep, cur)
    local v = cells.display_span_to_byte_span(cjk_data, s.from, s.to)
    assert.equals('99', vim.trim(cjk_data:sub(v.from + 1, v.to + 1)))
    local h = cells.display_span_to_byte_span(cjk_header, s.from, s.to)
    assert.equals('id', vim.trim(cjk_header:sub(h.from + 1, h.to + 1)))
  end)
end)

describe('dbout.parse_header', function()
  it('extracts postgres columns', function()
    local cols = dbout.parse_header(' id | name ', '----+------')
    assert.same({ 'id', 'name' }, cols)
  end)

  it('extracts mysql columns, dropping the border artifacts', function()
    local cols = dbout.parse_header('| id | name |', '+----+------+')
    assert.same({ 'id', 'name' }, cols)
  end)
end)

describe('dbout.foreign_select', function()
  local template = 'select * from "%s"."%s" where "%s" = %s'

  it('quotes a string cell value', function()
    assert.equals(
      [[select * from "public"."users" where "id" = 'ada']],
      dbout.foreign_select(template, 'public', 'users', 'id', 'ada')
    )
  end)

  it('leaves a numeric cell value bare', function()
    assert.equals(
      'select * from "public"."users" where "id" = 5',
      dbout.foreign_select(template, 'public', 'users', 'id', '5')
    )
  end)
end)

describe('schemas dbout metadata', function()
  it('postgres carries the FK / cell / layout fields', function()
    local s = schemas.get('postgres')
    assert.is_not_nil(s.foreign_key_query)
    assert.matches('{col_name}', s.foreign_key_query)
    assert.equals('select * from "%s"."%s" where "%s" = %s', s.select_foreign_key_query)
    assert.equals(2, s.cell_line_number)
    assert.is_not_nil(s.cell_line_pattern)
    assert.equals('\\x', s.layout_flag)
  end)

  it('mysql carries its FK / cell / layout fields', function()
    local s = schemas.get('mysql')
    assert.is_not_nil(s.foreign_key_query)
    assert.equals(3, s.cell_line_number)
    assert.equals('\\G', s.layout_flag)
  end)

  it('sqlite carries dbout nav metadata but no schema support', function()
    local s = schemas.get('sqlite')
    assert.is_not_nil(s.foreign_key_query)
    assert.matches('{col_name}', s.foreign_key_query)
    assert.equals('select * from "%s"."%s" where "%s" = %s', s.select_foreign_key_query)
    assert.equals(2, s.cell_line_number)
    -- still the tables-only drawer path: no schema listing, no layout toggle
    assert.is_nil(s.schemes_query)
    assert.is_nil(s.layout_flag)
  end)

  it('sqlite3 aliases the same adapter', function()
    assert.is_not_nil(schemas.get('sqlite3').foreign_key_query)
  end)
end)

describe('dbout foreign-key jump (sqlite, end-to-end)', function()
  local drawer_mod = require('dadbod-ui.drawer')
  local state = require('dadbod-ui.state')
  local config = require('dadbod-ui.config')
  local fixture = '/tmp/dbui_fk_sqlite.db'
  local d

  before_each(function()
    if vim.fn.executable('sqlite3') == 1 then
      vim.fn.delete(fixture)
      vim.fn.system({
        'sqlite3',
        fixture,
        table.concat({
          'CREATE TABLE authors(id INTEGER PRIMARY KEY, name TEXT);',
          'CREATE TABLE books(id INTEGER PRIMARY KEY, title TEXT, author_id INTEGER REFERENCES authors(id));',
          "INSERT INTO authors VALUES (1,'Ada Lovelace'),(2,'Alan Turing');",
          "INSERT INTO books VALUES (1,'Notes',1),(2,'Computable Numbers',2);",
        }, ' '),
      })
    end
  end)

  after_each(function()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(b)
      if name:match('%.dbout$') or name:match('books') then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    if d then
      d:close()
      d = nil
    end
    vim.fn.delete(fixture)
  end)

  -- The dbout buffers whose lines contain `text`.
  local function dbout_with(text)
    return vim.iter(vim.api.nvim_list_bufs()):find(function(b)
      if not vim.api.nvim_buf_get_name(b):match('%.dbout$') then
        return false
      end
      return vim.iter(vim.api.nvim_buf_get_lines(b, 0, -1, false)):any(function(l)
        return l:find(text, 1, true) ~= nil
      end)
    end)
  end

  it('jumps from a books.author_id cell to the referenced author row', function()
    if vim.fn.executable('sqlite3') ~= 1 then
      return pending('sqlite3 not installed')
    end
    local cfg = config.resolve({
      save_location = '/tmp/dbui_fk_qa',
      drawer = { show_help = false },
      query = { execute_on_save = true },
    })
    local instance = state.new(cfg):populate({ env = {}, g_dbs = { qa = 'sqlite:' .. fixture }, file_entries = {} })
    d = drawer_mod.new(instance)
    d.connector = require('dadbod-ui.bridge').connect
    d:open()
    local entry = instance.dbs[instance.dbs_list[1].key_name]

    -- run a query that surfaces the foreign-key column
    d:query():open({ type = 'query', key_name = entry.key_name }, 'edit')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'SELECT id, title, author_id FROM books ORDER BY id;' })
    vim.cmd('silent write')

    local result_buf = vim.wait(5000, function()
      return dbout_with('author_id') ~= nil
    end, 50) and dbout_with('author_id')
    assert.is_truthy(result_buf, 'expected the query result in a .dbout buffer')

    -- focus the result window and point the cursor at the author_id cell of row 1
    vim.api.nvim_set_current_win(vim.fn.win_findbuf(result_buf)[1])
    local header = vim.api.nvim_buf_get_lines(result_buf, 0, 1, false)[1]
    local col = assert(header:find('author_id')) -- 1-based start == 0-based span start
    local lines = vim.api.nvim_buf_get_lines(result_buf, 0, -1, false)
    local data_lnum
    for i = 3, #lines do
      if lines[i]:match('%S') then
        data_lnum = i
        break
      end
    end
    vim.api.nvim_win_set_cursor(0, { data_lnum, col })

    require('dadbod-ui.dbout').jump_to_foreign_table()

    local jumped = vim.wait(5000, function()
      return dbout_with('Ada Lovelace') ~= nil
    end, 50)
    assert.is_true(jumped, 'expected the FK jump to open the referenced author row')
  end)
end)

describe('dbout foreign-key jump (postgres, guarded)', function()
  it('runs the lookup + jump against a real adapter', function()
    if vim.fn.executable('psql') ~= 1 then
      return pending('psql not installed')
    end
    local url = os.getenv('DBUI_TEST_PG_URL')
    if url == nil or url == '' then
      return pending('set DBUI_TEST_PG_URL to a reachable postgres to exercise the FK jump')
    end
    -- The adapter exposes a foreign_key_query for postgres (sqlite does not).
    local scheme_info = schemas.get('postgres')
    assert.is_not_nil(scheme_info.foreign_key_query)
    assert.is_not_nil(scheme_info.select_foreign_key_query)
  end)
end)
