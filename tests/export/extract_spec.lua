-- Specs for dadbod-ui.export_extract: parsing a CLI's canonical delimited output
-- into the ExportData intermediate. RFC-4180 CSV (psql/sqlite) and mysql --batch
-- TSV (with \N NULLs). Pure: string in, table out.

local extract = require('dadbod-ui.export_extract')
local fmt = require('dadbod-ui.export_formats')

describe('export_extract.from_csv', function()
  it('parses a simple CSV with header into columns + rows', function()
    local data = extract.from_csv('id,name\n1,Ann\n2,Bob')
    assert.are.same({ 'id', 'name' }, data.columns)
    assert.are.same({ { '1', 'Ann' }, { '2', 'Bob' } }, data.rows)
  end)

  it('handles quoted fields with embedded delimiter, newline and doubled quotes', function()
    local csv = table.concat({
      'a,b',
      '"has, comma","line',
      'break"',
      '"say ""hi""",plain',
    }, '\n')
    local data = extract.from_csv(csv)
    assert.are.same({ 'a', 'b' }, data.columns)
    assert.are.same({
      { 'has, comma', 'line\nbreak' },
      { 'say "hi"', 'plain' },
    }, data.rows)
  end)

  it('keeps an empty field as empty string (NULL is indistinguishable, LIMITATION-001)', function()
    local data = extract.from_csv('a,b,c\n1,,3')
    assert.are.same({ '1', '', '3' }, data.rows[1])
    assert.are_not.equal(fmt.NULL, data.rows[1][2])
  end)

  it('does not emit a spurious trailing row for a trailing newline', function()
    local data = extract.from_csv('a\n1\n')
    assert.are.equal(1, #data.rows)
  end)

  it('round-trips a NULL-free fixture through fmt.csv', function()
    local original = {
      columns = { 'id', 'name', 'note' },
      rows = {
        { '1', 'Ann', '' },
        { '2', "O'Brien", 'has, comma' },
        { '3', 'Zoë', 'line\nbreak' },
      },
    }
    local data = extract.from_csv(fmt.csv(original))
    assert.are.same(original.columns, data.columns)
    assert.are.same(original.rows, data.rows)
  end)

  it('parses an empty document to empty columns/rows', function()
    local data = extract.from_csv('')
    assert.are.same({}, data.columns)
    assert.are.same({}, data.rows)
  end)
end)

describe('export_extract.from_tsv', function()
  it('parses tab-separated rows with a header', function()
    local data = extract.from_tsv('id\tname\n1\tAnn')
    assert.are.same({ 'id', 'name' }, data.columns)
    assert.are.same({ { '1', 'Ann' } }, data.rows)
  end)

  it('maps a lone \\N to the NULL sentinel and unescapes \\t \\n \\\\', function()
    local data = extract.from_tsv('a\tb\tc\n\\N\tx\\ty\tline\\nbreak')
    assert.are.equal(fmt.NULL, data.rows[1][1])
    assert.are.equal('x\ty', data.rows[1][2])
    assert.are.equal('line\nbreak', data.rows[1][3])
  end)

  it('maps a literal NULL field to the sentinel (MariaDB client, LIMITATION-003)', function()
    local data = extract.from_tsv('a\tb\nNULL\tkeep')
    assert.are.equal(fmt.NULL, data.rows[1][1])
    assert.are.equal('keep', data.rows[1][2])
  end)

  it('never maps a header field named NULL (only data rows are nullable)', function()
    local data = extract.from_tsv('NULL\tb\n1\t2')
    assert.are.same({ 'NULL', 'b' }, data.columns)
  end)

  it('drops a single trailing newline without a spurious row', function()
    local data = extract.from_tsv('a\n1\n')
    assert.are.equal(1, #data.rows)
  end)
end)

describe('export_extract.parse (dispatch)', function()
  it('routes mysql/mariadb to TSV (recovering NULLs) and others to CSV', function()
    assert.are.equal(fmt.NULL, extract.parse('mysql', 'a\n\\N').rows[1][1])
    assert.are.equal(fmt.NULL, extract.parse('mariadb', 'a\n\\N').rows[1][1])
    -- MariaDB client renders NULL as the literal word under --batch
    assert.are.equal(fmt.NULL, extract.parse('mysql', 'a\nNULL').rows[1][1])
    -- CSV path: a literal \N is just text, not NULL
    assert.are.equal('\\N', extract.parse('postgres', 'a\n\\N').rows[1][1])
  end)
end)
