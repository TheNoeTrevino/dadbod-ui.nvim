local declaration = require('dadbod-ui.declaration')

-- The treesitter half needs a `sql` parser. The suite runs on an isolated
-- stdpath (see minit.lua), so first try the rtp, then borrow the developer's
-- installed parser; without one the treesitter cases are skipped (the word
-- fallback below is exercised regardless, via broken SQL).
-- `language.add` reports failure as `nil, err` (it does not throw).
local has_sql = vim.treesitter.language.add('sql') == true
if not has_sql and vim.env.HOME ~= nil then
  local hits = vim.fn.glob(vim.env.HOME .. '/.local/share/nvim/**/parser/sql.so', true, true)
  if hits[1] ~= nil then
    has_sql = vim.treesitter.language.add('sql', { path = hits[1] }) == true
  end
end

describe('declaration.candidates (treesitter)', function()
  if not has_sql then
    it('is skipped without a sql treesitter parser', function() end)
    return
  end

  it('reads a plain relation', function()
    assert.same({ { name = 'users' } }, declaration.candidates('select * from users', 0, 15))
  end)

  it('reads a schema-qualified relation', function()
    assert.same({ { schema = 'public', name = 'users' } }, declaration.candidates('select * from public.users', 0, 22))
  end)

  it('keeps schema.table from a db.schema.table reference', function()
    assert.same({ { schema = 'dbo', name = 'users' } }, declaration.candidates('select * from db1.dbo.users', 0, 23))
  end)

  it('resolves a field alias qualifier through the from clause', function()
    local sql = 'select u.id from public.users u where u.id = 1'
    assert.same({ { schema = 'public', name = 'users' }, { name = 'u' } }, declaration.candidates(sql, 0, 7))
  end)

  it('resolves an alias defined in a join', function()
    local sql = 'select o.total from users u join orders o on o.user_id = u.id'
    assert.same({ { name = 'orders' }, { name = 'o' } }, declaration.candidates(sql, 0, 7))
  end)

  it('resolves the alias next to the relation itself', function()
    assert.same({ { name = 'users' } }, declaration.candidates('select * from users u', 0, 20))
  end)

  it('treats an unaliased field qualifier as a table name', function()
    assert.same({ { name = 'users' } }, declaration.candidates('select users.id from users', 0, 8))
  end)

  it('reads insert/update/delete targets', function()
    assert.same(
      { { schema = 'public', name = 'users' } },
      declaration.candidates("insert into public.users (name) values ('x')", 0, 20)
    )
    assert.same({ { name = 'users' } }, declaration.candidates("update users set name = 'x'", 0, 8))
    assert.same({ { name = 'stock' } }, declaration.candidates('delete from stock where id = 2', 0, 13))
  end)

  it('unquotes quoted identifiers', function()
    assert.same(
      { { schema = 'Weird', name = 'My Table' } },
      declaration.candidates('select * from "Weird"."My Table"', 0, 25)
    )
    assert.same({ { schema = 'my db', name = 'users' } }, declaration.candidates('select * from `my db`.users', 0, 23))
  end)

  it('returns nothing on a bare column or keyword', function()
    assert.same({}, declaration.candidates('select id from users', 0, 8))
    assert.same({}, declaration.candidates('select * from users', 0, 10))
  end)

  it('uses the cursor line in multi-line SQL', function()
    local sql = 'select *\nfrom public.users\nwhere id = 1'
    assert.same({ { schema = 'public', name = 'users' } }, declaration.candidates(sql, 1, 13))
  end)
end)

-- Broken SQL parses to an ERROR node, so these take the word fallback even
-- when a parser is installed -- and they are the whole path when it is not.
describe('declaration.candidates (word fallback)', function()
  it('reads a plain word', function()
    assert.same({ { name = 'users' } }, declaration.candidates('selec * from users', 0, 14))
  end)

  it('splits a qualified word, keeping a bare-name fallback', function()
    assert.same(
      { { schema = 'public', name = 'users' }, { name = 'users' } },
      declaration.candidates('selec * from public.users', 0, 21)
    )
  end)

  it('returns nothing off-word', function()
    assert.same({}, declaration.candidates('selec * from users', 0, 5))
    assert.same({}, declaration.candidates('', 0, 0))
  end)
end)

describe('declaration.match', function()
  local flat = {
    schema_support = false,
    default_scheme = '',
    tables = { 'Orders', 'users' },
    schemas = { list = {}, items = {} },
  }
  local schemad = {
    schema_support = true,
    default_scheme = 'public',
    tables = { 'logs', 'users' },
    schemas = {
      list = { 'audit', 'public' },
      items = { public = { 'users' }, audit = { 'logs', 'users' } },
    },
  }

  it('matches a flat adapter by bare name, ignoring qualifiers', function()
    assert.same({ schema = '', table = 'users' }, declaration.match(flat, { { name = 'users' } }))
    assert.same({ schema = '', table = 'users' }, declaration.match(flat, { { schema = 'main', name = 'users' } }))
  end)

  it('matches case-insensitively, returning the canonical name', function()
    assert.same({ schema = '', table = 'Orders' }, declaration.match(flat, { { name = 'orders' } }))
    assert.same(
      { schema = 'public', table = 'users' },
      declaration.match(schemad, { { schema = 'PUBLIC', name = 'USERS' } })
    )
  end)

  it('resolves an unqualified name through the default schema', function()
    assert.same({ schema = 'public', table = 'users' }, declaration.match(schemad, { { name = 'users' } }))
  end)

  it('prefers the buffer schema over the default', function()
    assert.same({ schema = 'audit', table = 'users' }, declaration.match(schemad, { { name = 'users' } }, 'audit'))
  end)

  it('falls through the schema list for names outside the default', function()
    assert.same({ schema = 'audit', table = 'logs' }, declaration.match(schemad, { { name = 'logs' } }))
  end)

  it('honors an explicit schema qualifier', function()
    assert.same(
      { schema = 'audit', table = 'users' },
      declaration.match(schemad, { { schema = 'audit', name = 'users' } })
    )
  end)

  it('takes the first candidate that matches', function()
    assert.same(
      { schema = 'audit', table = 'logs' },
      declaration.match(schemad, { { name = 'missing' }, { name = 'logs' } })
    )
  end)

  it('returns nil when nothing matches', function()
    assert.is_nil(declaration.match(schemad, { { name = 'nope' } }))
    assert.is_nil(declaration.match(schemad, { { schema = 'nope', name = 'users' } }))
    assert.is_nil(declaration.match(flat, { { name = 'nope' } }))
    assert.is_nil(declaration.match(schemad, {}))
  end)
end)
