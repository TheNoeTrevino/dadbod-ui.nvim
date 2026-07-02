-- Specs for the pure bind-parameter core (M9): detection, value quoting, and
-- substitution. No buffer, engine, or config is touched here -- these are plain
-- string transforms, so they run without any DB binary.

local bind = require('dadbod-ui.bind_params')

local DEFAULT = ':\\w\\+'

describe('bind_params.detect', function()
  it('finds a single placeholder', function()
    assert.same({ ':id' }, bind.detect({ 'SELECT * FROM t WHERE id = :id' }, DEFAULT))
  end)

  it('returns distinct names in first-seen order, deduping repeats', function()
    local lines = { 'SELECT :a, :b', 'WHERE x = :a OR y = :c' }
    assert.same({ ':a', ':b', ':c' }, bind.detect(lines, DEFAULT))
  end)

  it('ignores ::type casts (colon-prefixed)', function()
    assert.same({}, bind.detect({ 'SELECT x::text, y::int FROM t' }, DEFAULT))
  end)

  it('still finds a real placeholder alongside a cast', function()
    assert.same({ ':name' }, bind.detect({ 'SELECT x::text WHERE name = :name' }, DEFAULT))
  end)

  it('ignores placeholders inside single-quoted string literals', function()
    assert.same({}, bind.detect({ "SELECT 'hello :id world' FROM t" }, DEFAULT))
  end)

  it('finds an unquoted placeholder even when text mentions one in a literal', function()
    assert.same({ ':id' }, bind.detect({ "SELECT ':id literal', id FROM t WHERE id = :id" }, DEFAULT))
  end)

  it('honors a custom $N pattern', function()
    assert.same({ '$1', '$2' }, bind.detect({ 'SELECT * FROM t WHERE a = $1 AND b = $2' }, '\\$\\d\\+'))
  end)

  it('returns empty when nothing matches', function()
    assert.same({}, bind.detect({ 'SELECT 1' }, DEFAULT))
  end)

  it('matches a placeholder at column 0 (improves on the original)', function()
    assert.same({ ':id' }, bind.detect({ ':id' }, DEFAULT))
  end)

  it('ignores a placeholder in a -- line comment', function()
    assert.same({}, bind.detect({ 'SELECT 1 -- todo :later' }, DEFAULT))
  end)

  it('still detects a real placeholder before a -- comment on the same line', function()
    assert.same({ ':id' }, bind.detect({ 'WHERE id = :id -- note :skip' }, DEFAULT))
  end)

  it('ignores a placeholder in a single-line /* */ comment', function()
    assert.same({}, bind.detect({ 'SELECT 1 /* :todo */ FROM t' }, DEFAULT))
  end)

  it('ignores a placeholder in a multi-line /* */ comment', function()
    local lines = { 'SELECT 1 /* start', 'still :inside the block', 'end */ , :real' }
    assert.same({ ':real' }, bind.detect(lines, DEFAULT))
  end)

  it('ignores a placeholder in a multi-line single-quoted string', function()
    local lines = { "SELECT 'line one :a", "line two :b' AS s, id = :c" }
    assert.same({ ':c' }, bind.detect(lines, DEFAULT))
  end)

  it('does not let an apostrophe in a double-quoted identifier flip string state', function()
    -- Regression: the lexer used to track only '...' literals, so the apostrophe
    -- in "customer's" opened a bogus string and swallowed the trailing :id.
    assert.same({ ':id' }, bind.detect({ [[SELECT "customer's", :id FROM t]] }, DEFAULT))
  end)

  it('ignores a placeholder inside a double-quoted identifier', function()
    assert.same({ ':real' }, bind.detect({ [[SELECT "col :nope" , :real FROM t]] }, DEFAULT))
  end)

  it('honors a "" escape inside a double-quoted identifier', function()
    assert.same({ ':id' }, bind.detect({ [[SELECT "a""b" , :id FROM t]] }, DEFAULT))
  end)

  it('does not let a quote in a dollar-quoted body flip string state', function()
    -- Regression: a stray ' inside $$...$$ used to open a string and hide :id.
    assert.same({ ':id' }, bind.detect({ "SELECT $$ don't :skip $$, :id FROM t" }, DEFAULT))
  end)

  it('ignores a placeholder inside a tagged dollar-quoted body', function()
    assert.same({ ':real' }, bind.detect({ 'SELECT $tag$ :skip $tag$, :real' }, DEFAULT))
  end)

  it('ignores a placeholder in a multi-line dollar-quoted body', function()
    local lines = { 'SELECT $$ start :a', 'still :b inside $$, :real' }
    assert.same({ ':real' }, bind.detect(lines, DEFAULT))
  end)
end)

describe('bind_params.quote', function()
  it('wraps a plain string in single quotes', function()
    assert.equals("'ada'", bind.quote('ada'))
  end)

  it('escapes embedded single quotes', function()
    assert.equals("'O''Brien'", bind.quote("O'Brien"))
  end)

  it('passes integers through bare', function()
    assert.equals('42', bind.quote('42'))
    assert.equals('-7', bind.quote('-7'))
  end)

  it('passes decimals through bare', function()
    assert.equals('3.14', bind.quote('3.14'))
  end)

  it('passes booleans and NULL through bare, case-insensitively', function()
    assert.equals('true', bind.quote('true'))
    assert.equals('FALSE', bind.quote('FALSE'))
    assert.equals('NULL', bind.quote('NULL'))
  end)

  it('leaves an already-quoted literal untouched', function()
    assert.equals("'already'", bind.quote("'already'"))
  end)
end)

describe('bind_params.substitute', function()
  it('substitutes a quoted string value', function()
    local out = bind.substitute({ 'WHERE name = :name' }, { [':name'] = 'ada' }, DEFAULT)
    assert.same({ "WHERE name = 'ada'" }, out)
  end)

  it('substitutes a numeric value bare', function()
    local out = bind.substitute({ 'WHERE id = :id' }, { [':id'] = '5' }, DEFAULT)
    assert.same({ 'WHERE id = 5' }, out)
  end)

  it('replaces every occurrence of a repeated placeholder', function()
    local out = bind.substitute({ 'a = :x OR b = :x' }, { [':x'] = '1' }, DEFAULT)
    assert.same({ 'a = 1 OR b = 1' }, out)
  end)

  it('substitutes multiple distinct placeholders on one line', function()
    local out = bind.substitute({ ':a and :b' }, { [':a'] = 'x', [':b'] = 'y' }, DEFAULT)
    assert.same({ "'x' and 'y'" }, out)
  end)

  it('leaves a placeholder with a blank value as a raw literal', function()
    local out = bind.substitute({ 'WHERE id = :id' }, { [':id'] = '   ' }, DEFAULT)
    assert.same({ 'WHERE id = :id' }, out)
  end)

  it('leaves a placeholder with no value untouched', function()
    local out = bind.substitute({ 'WHERE id = :id' }, {}, DEFAULT)
    assert.same({ 'WHERE id = :id' }, out)
  end)

  it('does not substitute inside string literals or ::casts', function()
    local out = bind.substitute({ "SELECT ':id', x::id, :id" }, { [':id'] = '9' }, DEFAULT)
    assert.same({ "SELECT ':id', x::id, 9" }, out)
  end)

  it('works with a custom $N pattern', function()
    local out = bind.substitute({ 'a = $1 AND b = $2' }, { ['$1'] = 'foo', ['$2'] = '2' }, '\\$\\d\\+')
    assert.same({ "a = 'foo' AND b = 2" }, out)
  end)

  it('does not substitute inside comments', function()
    local lines = { 'WHERE id = :id -- keep :id literal', '/* :id */ AND x = :id' }
    local out = bind.substitute(lines, { [':id'] = '7' }, DEFAULT)
    assert.same({ 'WHERE id = 7 -- keep :id literal', '/* :id */ AND x = 7' }, out)
  end)

  it('does not substitute inside a multi-line string literal', function()
    local lines = { "note = 'first :x", "second :x' AND id = :x" }
    local out = bind.substitute(lines, { [':x'] = '1' }, DEFAULT)
    assert.same({ "note = 'first :x", "second :x' AND id = 1" }, out)
  end)

  it('substitutes after a double-quoted identifier containing an apostrophe', function()
    local out = bind.substitute({ [[SELECT "customer's" WHERE id = :id]] }, { [':id'] = '9' }, DEFAULT)
    assert.same({ [[SELECT "customer's" WHERE id = 9]] }, out)
  end)

  it('does not substitute inside a dollar-quoted body', function()
    local out = bind.substitute({ 'SELECT $$ :skip $$, :id' }, { [':skip'] = 'x', [':id'] = '9' }, DEFAULT)
    assert.same({ 'SELECT $$ :skip $$, 9' }, out)
  end)
end)
