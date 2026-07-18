-- Specs for dadbod-ui.export.formats: the pure result formatters (CSV/TSV/JSON/
-- Markdown/HTML/XML/SQL) over the canonical ExportData intermediate. No Neovim
-- buffers and no database -- string in, string out -- so these are exhaustive and
-- fast. Fixtures here are the acceptance fixtures from specs/native-export.md §5.

local fmt = require('dadbod-ui.export.formats')

-- The shared §5 fixture: an `id,name,note` result whose rows exercise NULL, an
-- embedded delimiter, an apostrophe (not the quote char), and an embedded newline.
local function fixture()
  return {
    columns = { 'id', 'name', 'note' },
    rows = {
      { '1', 'Ann', fmt.NULL },
      { '2', "O'Brien", 'has, comma' },
      { '3', 'Zoë', 'line\nbreak' },
    },
    source = 't',
  }
end

describe('export.formats.NULL', function()
  it('is a stable unique sentinel distinct from empty string and nil', function()
    assert.are_not.equal('', fmt.NULL)
    assert.is_not_nil(fmt.NULL)
    assert.are.equal(fmt.NULL, fmt.NULL)
  end)
end)

describe('export.formats.csv', function()
  it('renders the §5.1 fixture with default options', function()
    local expected = table.concat({
      'id,name,note',
      '1,Ann,',
      '2,O\'Brien,"has, comma"',
      '3,Zoë,"line',
      'break"',
    }, '\n')
    assert.are.equal(expected, fmt.csv(fixture()))
  end)

  it('quotes only fields containing the delimiter, quote char, CR or LF', function()
    local data = {
      columns = { 'a', 'b' },
      rows = { { 'plain', 'has"quote' }, { 'has,comma', 'has\rcr' } },
    }
    local expected = table.concat({
      'a,b',
      'plain,"has""quote"', -- doubled quote, wrapped
      '"has,comma","has\rcr"',
    }, '\n')
    assert.are.equal(expected, fmt.csv(data))
  end)

  it('omits the header when header=false', function()
    local out = fmt.csv({ columns = { 'a' }, rows = { { 'x' } } }, { header = false })
    assert.are.equal('x', out)
  end)

  it('renders NULL as null_string (default empty, configurable)', function()
    local data = { columns = { 'a', 'b' }, rows = { { fmt.NULL, 'y' } } }
    assert.are.equal('a,b\n,y', fmt.csv(data))
    assert.are.equal('a,b\n\\N,y', fmt.csv(data, { null_string = '\\N' }))
  end)

  it('honours a custom delimiter', function()
    local data = { columns = { 'a', 'b' }, rows = { { '1', '2' } } }
    assert.are.equal('a;b\n1;2', fmt.csv(data, { delimiter = ';' }))
  end)
end)

describe('export.formats.tsv', function()
  it('separates with tabs, no quoting, escaping embedded newlines to the literal', function()
    local expected = table.concat({
      'id\tname\tnote',
      '1\tAnn\t',
      "2\tO'Brien\thas, comma",
      '3\tZoë\tline\\nbreak',
    }, '\n')
    assert.are.equal(expected, fmt.tsv(fixture()))
  end)

  it('escapes an embedded tab so columns stay aligned', function()
    local data = { columns = { 'a', 'b' }, rows = { { 'x\ty', 'z' } } }
    assert.are.equal('a\tb\nx\\ty\tz', fmt.tsv(data))
  end)

  it('escapes a literal backslash first, so it stays distinct from an escaped tab', function()
    -- regression: without escaping '\' -> '\\' FIRST, a literal two-char "\t" in
    -- the data would be indistinguishable from an escaped real tab.
    local data = { columns = { 'a' }, rows = { { 'back\\slash' } } }
    assert.are.equal('a\nback\\\\slash', fmt.tsv(data))

    local literal_bs_t = { columns = { 'a', 'b' }, rows = { { 'x\\ty', 'z' } } } -- literal backslash + 't', not a tab
    local real_tab = { columns = { 'a', 'b' }, rows = { { 'x\ty', 'z' } } } -- a real tab char
    assert.are_not.equal(fmt.tsv(literal_bs_t), fmt.tsv(real_tab)) -- must not collide
  end)
end)

describe('export.formats.csv: replacement strings with %', function()
  it('does not raise on a line_feed_escape / escape_delimiter containing %', function()
    -- regression: a raw '%' in a gsub REPLACEMENT string errors ("invalid use of
    -- '%' in replacement string"); user-configured escape strings must be safe.
    local data = { columns = { 'a', 'b' }, rows = { { 'line\nbreak', 'has,comma' } } }
    local ok, out = pcall(fmt.csv, data, {
      quote = '',
      line_feed_escape = '%n',
      escape_delimiter = '%d',
    })
    assert.is_true(ok)
    assert.are.equal('a,b\nline%nbreak,has%dcomma', out)
  end)
end)

describe('export.formats.json', function()
  it('renders the §5.3 fixture (unwrapped, no number coercion)', function()
    local expected = table.concat({
      '[',
      '\t{',
      '\t\t"id" : "1",',
      '\t\t"name" : "Ann",',
      '\t\t"note" : null',
      '\t},',
      '\t{',
      '\t\t"id" : "2",',
      '\t\t"name" : "O\'Brien",',
      '\t\t"note" : "has, comma"',
      '\t},',
      '\t{',
      '\t\t"id" : "3",',
      '\t\t"name" : "Zoë",',
      '\t\t"note" : "line\\nbreak"',
      '\t}',
      ']',
    }, '\n')
    assert.are.equal(expected, fmt.json(fixture(), { wrap_table_name = false }))
  end)

  it('wraps the array under the source name by default', function()
    local data = { columns = { 'a' }, rows = { { 'x' } }, source = 'tbl' }
    local out = fmt.json(data)
    assert.are.equal('{\n"tbl": [\n\t{\n\t\t"a" : "x"\n\t}\n]}', out)
  end)

  it('emits null for the NULL sentinel and never the literal string', function()
    local data = { columns = { 'a' }, rows = { { fmt.NULL } } }
    assert.is_truthy(fmt.json(data, { wrap_table_name = false }):find('"a" : null', 1, true))
  end)

  it('coerces numbers and booleans only when coerce_numbers=true', function()
    local data = { columns = { 'n', 'b', 's' }, rows = { { '42', 'true', 'hi' } } }
    local on = fmt.json(data, { wrap_table_name = false, coerce_numbers = true })
    assert.is_truthy(on:find('"n" : 42', 1, true))
    assert.is_truthy(on:find('"b" : true', 1, true))
    assert.is_truthy(on:find('"s" : "hi"', 1, true))
    local off = fmt.json(data, { wrap_table_name = false })
    assert.is_truthy(off:find('"n" : "42"', 1, true))
  end)

  it('keeps numeric-looking strings that are not valid JSON numbers quoted', function()
    -- leading zero, trailing dot, exponent, leading + => stay quoted strings
    local data = { columns = { 'a', 'b', 'c', 'd', 'e', 'f' }, rows = { { '007', '1.', '1e5', '+1', '0', '3.14' } } }
    local out = fmt.json(data, { wrap_table_name = false, coerce_numbers = true })
    assert.is_truthy(out:find('"a" : "007"', 1, true))
    assert.is_truthy(out:find('"b" : "1."', 1, true))
    assert.is_truthy(out:find('"c" : "1e5"', 1, true))
    assert.is_truthy(out:find('"d" : "+1"', 1, true))
    assert.is_truthy(out:find('"e" : 0', 1, true)) -- valid
    assert.is_truthy(out:find('"f" : 3.14', 1, true)) -- valid
  end)

  it('escapes JSON string control chars and quotes', function()
    local data = { columns = { 'a' }, rows = { { 'q"\\\tx' } } }
    assert.is_truthy(fmt.json(data, { wrap_table_name = false }):find('"a" : "q\\"\\\\\\tx"', 1, true))
  end)

  it('renders an empty result as an empty array', function()
    assert.are.equal('[]', fmt.json({ columns = { 'a' }, rows = {} }, { wrap_table_name = false }))
  end)
end)

describe('export.formats.markdown', function()
  it('renders the §5.4 fixture', function()
    local expected = table.concat({
      '| id | name | note |',
      '| --- | --- | --- |',
      '| 1 | Ann |  |',
      "| 2 | O'Brien | has, comma |",
      '| 3 | Zoë | line<br>break |',
    }, '\n')
    assert.are.equal(expected, fmt.markdown(fixture()))
  end)

  it('escapes pipes in cell content', function()
    local data = { columns = { 'a' }, rows = { { 'x|y' } } }
    assert.is_truthy(fmt.markdown(data):find('| x\\|y |', 1, true))
  end)
end)

describe('export.formats.html', function()
  it('renders a thead/tbody table with the fixture rows', function()
    local out = fmt.html(fixture())
    assert.is_truthy(out:find('<table>', 1, true))
    assert.is_truthy(out:find('<tr><th>id</th><th>name</th><th>note</th></tr>', 1, true))
    assert.is_truthy(out:find('<tr><td>1</td><td>Ann</td><td></td></tr>', 1, true)) -- NULL -> empty
    assert.is_truthy(out:find('<td>line<br>break</td>', 1, true)) -- newline -> <br>
    assert.is_truthy(out:find('</tbody>\n</table>', 1, true))
  end)

  it('escapes HTML metacharacters', function()
    local data = { columns = { 'a' }, rows = { { '<b>&"x' } } }
    assert.is_truthy(fmt.html(data):find('<td>&lt;b&gt;&amp;&quot;x</td>', 1, true))
  end)
end)

describe('export.formats.xml', function()
  it('renders <data>/<row>/<col> with the fixture rows', function()
    local out = fmt.xml(fixture())
    assert.is_truthy(out:find('<?xml version="1.0" encoding="UTF-8"?>\n<data>', 1, true))
    assert.is_truthy(out:find('<col name="id">1</col>', 1, true))
    assert.is_truthy(out:find('<col name="note" isNull="true"/>', 1, true)) -- NULL row 1
    assert.is_truthy(out:find('<col name="name">O&apos;Brien</col>', 1, true))
    assert.is_truthy(out:find('</data>', 1, true))
  end)

  it('escapes XML metacharacters incl apostrophe', function()
    local data = { columns = { 'a' }, rows = { { '<x>&\'"' } } }
    assert.is_truthy(fmt.xml(data):find('<col name="a">&lt;x&gt;&amp;&apos;&quot;</col>', 1, true))
  end)
end)

describe('export.formats.sql', function()
  it('emits one INSERT per row, NULL bare, quotes doubled (unquoted identifiers)', function()
    local expected = table.concat({
      "INSERT INTO t (id, name, note) VALUES ('1', 'Ann', NULL);",
      "INSERT INTO t (id, name, note) VALUES ('2', 'O''Brien', 'has, comma');",
      "INSERT INTO t (id, name, note) VALUES ('3', 'Zoë', 'line\nbreak');",
    }, '\n')
    assert.are.equal(expected, fmt.sql(fixture()))
  end)

  it('quotes identifiers when quote_identifiers=true', function()
    local data = { columns = { 'id' }, rows = { { '1' } }, source = 't' }
    assert.are.equal('INSERT INTO "t" ("id") VALUES (\'1\');', fmt.sql(data, { quote_identifiers = true }))
  end)

  it('falls back to exported_table and coerces numbers when asked', function()
    local data = { columns = { 'n' }, rows = { { '42' } } }
    assert.are.equal('INSERT INTO exported_table (n) VALUES (42);', fmt.sql(data, { coerce_numbers = true }))
  end)

  it('doubles the quote char inside a quoted identifier so it stays balanced', function()
    -- regression: a column named a"b used to emit the broken `"a"b"`.
    local data = { columns = { 'a"b' }, rows = { { '1' } }, source = 't"1' }
    assert.are.equal('INSERT INTO "t""1" ("a""b") VALUES (\'1\');', fmt.sql(data, { quote_identifiers = true }))
  end)

  it('normalizes an empty-string opts.table / data.source to the exported_table fallback', function()
    -- regression: '' is truthy in Lua, so opts.table = '' (or data.source = '')
    -- used to win over the 'exported_table' fallback and emit a broken, empty
    -- identifier (`INSERT INTO  (...)`).
    local data = { columns = { 'n' }, rows = { { '1' } }, source = '' }
    assert.are.equal("INSERT INTO exported_table (n) VALUES ('1');", fmt.sql(data, { table = '' }))
    assert.are.equal("INSERT INTO exported_table (n) VALUES ('1');", fmt.sql(data))
  end)
end)
