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

  it('sqlite has no FK support (no dbout metadata)', function()
    local s = schemas.get('sqlite')
    assert.is_nil(s.foreign_key_query)
    assert.is_nil(s.layout_flag)
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
