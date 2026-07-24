-- Table-reference resolution for "go to declaration" (`gd` in query buffers)
--
-- Two pure halves, both side-effect free and testable without a drawer:
--   * `candidates(text, row, col)` reads the SQL under the cursor and returns
--     the table references it could mean, best guess first. Treesitter (the
--     `sql` grammar) is used when a parser is installed -- it understands
--     schema qualification and resolves relation aliases (`u` in `u.id` ->
--     `public.users`). Without a parser (or inside a parse error) it falls
--     back to splitting the WORD under the cursor on dots.
--   * `match(entry, candidates, preferred_schema)` checks those candidates
--     against a connection's introspected tables and returns the drawer
--     coordinates (`schema`, `table`) of the first hit, or nil.
--
-- The caller (Drawer:goto_table) owns everything stateful: reading the buffer,
-- introspecting when the entry is empty, and moving the cursor.

local M = {}

---@class DadbodUI.DeclarationCandidate
---@field name string        table name as written (unquoted)
---@field schema? string     schema qualifier, when written

---@class DadbodUI.DeclarationTarget
---@field schema string      canonical schema name ('' for flat adapters)
---@field table string       canonical table name

---@private
--- Strip one layer of SQL identifier quoting: `` `x` ``, `"x"` or `[x]`.
---@param s string
---@return string
local function unquote(s)
  return s:match('^`(.*)`$') or s:match('^"(.*)"$') or s:match('^%[(.*)%]$') or s
end

---@private
--- The first child of `node` with type `type_name`, or nil.
---@param node TSNode
---@param type_name string
---@return TSNode|nil
local function child_of_type(node, type_name)
  for child in node:iter_children() do
    if child:type() == type_name then
      return child
    end
  end
  return nil
end

---@private
--- The unquoted identifier parts of an `object_reference` node, in order
--- (e.g. `db.schema.table` -> three parts). `source` is the treesitter text
--- source (buffer number or string).
---@param ref TSNode
---@param source integer|string
---@return string[]
local function ref_parts(ref, source)
  local parts = {}
  for child in ref:iter_children() do
    if child:type() == 'identifier' then
      parts[#parts + 1] = unquote(vim.treesitter.get_node_text(child, source))
    end
  end
  return parts
end

---@private
--- A candidate from identifier parts: the last part is the table, the one
--- before it the schema -- so `db.schema.table` keeps `schema.table`, and a
--- lone part yields `schema = nil` (index 0 is nil). Callers never pass an
--- empty list (a non-ERROR `object_reference` always has an identifier; the
--- word path checks the word is non-empty before splitting).
---@param parts string[]
---@return DadbodUI.DeclarationCandidate
local function from_parts(parts)
  return { schema = parts[#parts - 1], name = parts[#parts] }
end

---@private
--- The nearest `statement` ancestor of `node` (alias scope), or the root.
---@param node TSNode
---@return TSNode
local function statement_scope(node)
  local n = node
  while n:parent() ~= nil do
    if n:type() == 'statement' then
      return n
    end
    n = n:parent()
  end
  return n
end

---@private
--- Resolve a relation alias within `scope`: find a `relation` node whose alias
--- identifier equals `alias` (case-insensitive, as unquoted SQL aliases are)
--- and return its `object_reference` parts.
---@param scope TSNode
---@param alias string
---@param source integer|string
---@return string[]|nil
local function resolve_alias(scope, alias, source)
  local want = alias:lower()
  local found = nil
  -- The `object_reference` parts when `node` is a relation aliased `want`, else
  -- nil -- flat guards so the alias test reads top to bottom.
  local function alias_parts(node)
    if node:type() ~= 'relation' then
      return nil
    end
    local a = node:field('alias')[1]
    if a == nil or unquote(vim.treesitter.get_node_text(a, source)):lower() ~= want then
      return nil
    end
    local ref = child_of_type(node, 'object_reference')
    return ref ~= nil and ref_parts(ref, source) or nil
  end
  -- Depth-first, short-circuiting on the first match: `:any` stops pulling
  -- children the moment `walk` returns true (unlike `:each`, which can't break).
  local function walk(node)
    local parts = alias_parts(node)
    if parts ~= nil then
      found = parts
      return true
    end
    return vim.iter(node:iter_children()):any(walk)
  end
  walk(scope)
  return found
end

---@private
--- The `sql` LanguageTree for `source` (a buffer number uses Neovim's cached,
--- incrementally-reparsed parser; a string builds a throwaway one), or nil when
--- no parser is installed.
---@param source integer|string
---@return vim.treesitter.LanguageTree|nil
local function sql_parser(source)
  local getter = type(source) == 'number' and vim.treesitter.get_parser or vim.treesitter.get_string_parser
  local ok, parser = pcall(getter, source, 'sql')
  if not ok then
    return nil
  end
  return parser
end

---@private
--- Resolve the cursor `node` to the `object_reference` whose parts to read, or
--- return `nil, terminal` when the node settles the question on its own -- the
--- cursor sits on a relation's alias (its table is the sibling reference) or on
--- a bare column/keyword (not a table at all, so `{}`). Flat guards, so the
--- caller is a two-line dispatch instead of a nested identifier branch.
---@param node TSNode
---@param source integer|string
---@return TSNode|nil ref
---@return DadbodUI.DeclarationCandidate[]|nil terminal
local function reference_node(node, source)
  if node:type() == 'object_reference' then
    return node
  end
  local parent = node:parent()
  if parent == nil then
    return nil, {}
  end
  if parent:type() == 'relation' then
    -- Cursor on a relation's alias (`u` in `from users u`).
    local sibling = child_of_type(parent, 'object_reference')
    return nil, sibling ~= nil and { from_parts(ref_parts(sibling, source)) } or {}
  end
  if parent:type() ~= 'object_reference' then
    -- A bare column, a keyword fragment: confidently not a table.
    return nil, {}
  end
  return parent
end

---@private
--- Treesitter candidates at (`row`, `col`), 0-based. Returns nil when the
--- grammar cannot tell (no parse, cursor inside an ERROR node) -- the caller
--- falls back to word matching -- and {} when it CAN tell the cursor is not on
--- a table reference (a bare column, a keyword), which stays a quiet no-op.
---@param source integer|string
---@param row integer
---@param col integer
---@return DadbodUI.DeclarationCandidate[]|nil
local function ts_candidates(source, row, col)
  local parser = sql_parser(source)
  if parser == nil then
    return nil
  end
  local tree = parser:parse()[1]
  if tree == nil then
    return nil
  end
  local node = tree:root():named_descendant_for_range(row, col, row, col)
  if node == nil or node:type() == 'ERROR' then
    return nil
  end
  if node:type() ~= 'identifier' and node:type() ~= 'object_reference' then
    return {}
  end

  local ref, terminal = reference_node(node, source)
  if ref == nil then
    return terminal
  end

  local parts = ref_parts(ref, source)
  local context = ref:parent() ~= nil and ref:parent():type() or ''
  -- The only reference that isn't just its own name is a single-part column
  -- qualifier (`u` in `u.id`): first try it as an alias, then as a table name.
  -- Everything else -- a relation, an insert/update/delete target, a CTE name,
  -- a schema-qualified `public.users.id` -- is the reference itself.
  if context == 'field' and #parts == 1 then
    local out = {}
    local resolved = resolve_alias(statement_scope(ref), parts[1], source)
    if resolved ~= nil then
      out[#out + 1] = from_parts(resolved)
    end
    out[#out + 1] = { name = parts[1] }
    return out
  end
  return { from_parts(parts) }
end

---@private
--- The `row`-th (0-based) line of `source` (a buffer number or a string).
---@param source integer|string
---@param row integer
---@return string
local function source_line(source, row)
  if type(source) == 'number' then
    return vim.api.nvim_buf_get_lines(source, row, row + 1, false)[1] or ''
  end
  return vim.split(source, '\n', { plain = true })[row + 1] or ''
end

---@private
--- Fallback candidates: the WORD under the cursor split on dots, unquoted.
--- Handles `users` and `public.users`; an alias qualifier like `u.id` simply
--- produces candidates that match nothing.
---@param source integer|string
---@param row integer
---@param col integer
---@return DadbodUI.DeclarationCandidate[]
local function word_candidates(source, row, col)
  local line = source_line(source, row)
  -- The identifier run (word chars, dots and quoting) covering the cursor.
  local word
  for start, run in line:gmatch('()([%w_$#%.`"%[%]]+)') do
    if start <= col + 1 and col + 1 < start + #run then
      word = run:gsub('^%.+', ''):gsub('%.+$', '')
      break
    end
  end
  if word == nil or word == '' then
    return {}
  end
  local parts = vim.tbl_map(unquote, vim.split(word, '.', { plain = true }))
  local out = { from_parts(parts) }
  if #parts > 1 then
    -- The schema-qualified guess may be an alias chain (`u.id`); the bare last
    -- part keeps a plain table hit alive.
    out[#out + 1] = { name = parts[#parts] }
  end
  return out
end

--- The table references the cursor could mean, best guess first. `source` is a
--- buffer number (uses the cached, incremental parser) or a string (for
--- drawer-free testing); `row`/`col` are 0-based (`nvim_win_get_cursor` row
--- minus one). Returns {} when the cursor is not on anything table-shaped.
---@param source integer|string
---@param row integer
---@param col integer
---@return DadbodUI.DeclarationCandidate[]
function M.candidates(source, row, col)
  local ts = ts_candidates(source, row, col)
  if ts ~= nil then
    return ts
  end
  return word_candidates(source, row, col)
end

---@private
--- Find `name` in `list`, exact match first, then case-insensitive (unquoted
--- SQL identifiers are case-folded per engine; the stored name is canonical).
---@param list string[]
---@param name string
---@return string|nil
local function find_name(list, name)
  local lower = name:lower()
  local fold_hit = nil
  for _, item in ipairs(list) do
    if item == name then
      return item
    end
    if fold_hit == nil and item:lower() == lower then
      fold_hit = item
    end
  end
  return fold_hit
end

---@private
--- The schema search order for an unqualified name: the query buffer's own
--- schema first, then the adapter default, then everything else.
---@param entry DadbodUI.ConnectionEntry
---@param preferred_schema? string
---@return string[]
local function schema_order(entry, preferred_schema)
  local order = {}
  local seen = {}
  local function add(schema)
    if schema ~= nil and schema ~= '' and not seen[schema] then
      seen[schema] = true
      order[#order + 1] = schema
    end
  end
  add(preferred_schema)
  add(entry.default_scheme)
  for _, schema in ipairs(entry.schemas.list) do
    add(schema)
  end
  return order
end

--- Match `candidates` against `entry`'s introspected tables. Returns the
--- drawer coordinates of the first hit -- canonical names, `schema` of '' for
--- flat (schema-less) adapters -- or nil when nothing matches.
---@param entry DadbodUI.ConnectionEntry
---@param candidates DadbodUI.DeclarationCandidate[]
---@param preferred_schema? string
---@return DadbodUI.DeclarationTarget|nil
function M.match(entry, candidates, preferred_schema)
  for _, cand in ipairs(candidates) do
    if not entry.schema_support then
      -- Flat adapters ignore any qualifier: `main.users` (sqlite) and
      -- `mydb.users` (single-database mysql) both mean the bare table.
      local name = find_name(entry.tables, cand.name)
      if name ~= nil then
        return { schema = '', table = name }
      end
    elseif cand.schema ~= nil then
      local schema = find_name(entry.schemas.list, cand.schema)
      local name = schema ~= nil and find_name(entry.schemas.items[schema] or {}, cand.name) or nil
      if name ~= nil then
        return { schema = schema, table = name }
      end
    else
      for _, schema in ipairs(schema_order(entry, preferred_schema)) do
        local name = find_name(entry.schemas.items[schema] or {}, cand.name)
        if name ~= nil then
          return { schema = schema, table = name }
        end
      end
    end
  end
  return nil
end

return M
