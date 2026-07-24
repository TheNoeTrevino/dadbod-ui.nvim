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
--- The unquoted identifier parts of an `object_reference` node, in order
--- (e.g. `db.schema.table` -> three parts).
---@param ref TSNode
---@param text string
---@return string[]
local function ref_parts(ref, text)
  local parts = {}
  for child in ref:iter_children() do
    if child:type() == 'identifier' then
      parts[#parts + 1] = unquote(vim.treesitter.get_node_text(child, text))
    end
  end
  return parts
end

---@private
--- A candidate from identifier parts: the last part is the table, the one
--- before it (if any) the schema -- so `db.schema.table` keeps `schema.table`.
---@param parts string[]
---@return DadbodUI.DeclarationCandidate|nil
local function from_parts(parts)
  if #parts == 0 then
    return nil
  end
  if #parts == 1 then
    return { name = parts[1] }
  end
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
---@param text string
---@return string[]|nil
local function resolve_alias(scope, alias, text)
  local want = alias:lower()
  local found = nil
  local function walk(node)
    if found ~= nil then
      return
    end
    if node:type() == 'relation' then
      local a = node:field('alias')[1]
      if a ~= nil and unquote(vim.treesitter.get_node_text(a, text)):lower() == want then
        for child in node:iter_children() do
          if child:type() == 'object_reference' then
            found = ref_parts(child, text)
            return
          end
        end
      end
    end
    for child in node:iter_children() do
      walk(child)
    end
  end
  walk(scope)
  return found
end

---@private
--- Treesitter candidates at (`row`, `col`), 0-based. Returns nil when the
--- grammar cannot tell (no parse, cursor inside an ERROR node) -- the caller
--- falls back to word matching -- and {} when it CAN tell the cursor is not on
--- a table reference (a bare column, a keyword), which stays a quiet no-op.
---@param text string
---@param row integer
---@param col integer
---@return DadbodUI.DeclarationCandidate[]|nil
local function ts_candidates(text, row, col)
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, 'sql')
  if not ok or parser == nil then
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

  local ref = node
  if node:type() == 'identifier' then
    local parent = node:parent()
    if parent == nil then
      return {}
    end
    if parent:type() == 'relation' then
      -- Cursor on a relation's alias (`u` in `from users u`): the table is the
      -- sibling object_reference.
      for child in parent:iter_children() do
        if child:type() == 'object_reference' then
          return { from_parts(ref_parts(child, text)) }
        end
      end
      return {}
    end
    if parent:type() ~= 'object_reference' then
      -- A bare column, a keyword fragment: confidently not a table.
      return {}
    end
    ref = parent
  end

  local parts = ref_parts(ref, text)
  local context = ref:parent() ~= nil and ref:parent():type() or ''
  if context == 'field' then
    -- Qualifier of a column (`u` in `u.id`, `public.users` in
    -- `public.users.id`): a lone part is first an alias, then a table name.
    if #parts == 1 then
      local out = {}
      local resolved = resolve_alias(statement_scope(ref), parts[1], text)
      if resolved ~= nil then
        out[#out + 1] = from_parts(resolved)
      end
      out[#out + 1] = { name = parts[1] }
      return out
    end
    return { from_parts(parts) }
  end
  -- A relation, insert/update/delete target, CTE name...: the reference itself.
  return { from_parts(parts) }
end

---@private
--- Fallback candidates: the WORD under the cursor split on dots, unquoted.
--- Handles `users` and `public.users`; an alias qualifier like `u.id` simply
--- produces candidates that match nothing.
---@param text string
---@param row integer
---@param col integer
---@return DadbodUI.DeclarationCandidate[]
local function word_candidates(text, row, col)
  local line = vim.split(text, '\n', { plain = true })[row + 1] or ''
  -- Expand around the cursor over identifier characters, dots and quoting.
  local is_word = function(c)
    return c ~= '' and c:match('[%w_$#%.`"%[%]]') ~= nil
  end
  local from = col + 1
  local to = col
  if not is_word(line:sub(from, from)) then
    return {}
  end
  while from > 1 and is_word(line:sub(from - 1, from - 1)) do
    from = from - 1
  end
  while to < #line and is_word(line:sub(to + 1, to + 1)) do
    to = to + 1
  end
  local word = line:sub(from, to):gsub('^%.+', ''):gsub('%.+$', '')
  if word == '' then
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

--- The table references the cursor could mean, best guess first. `row`/`col`
--- are 0-based (`nvim_win_get_cursor` row minus one). Returns {} when the
--- cursor is not on anything table-shaped.
---@param text string  the buffer's full text
---@param row integer
---@param col integer
---@return DadbodUI.DeclarationCandidate[]
function M.candidates(text, row, col)
  local ts = ts_candidates(text, row, col)
  if ts ~= nil then
    return ts
  end
  return word_candidates(text, row, col)
end

---@private
--- Find `name` in `list`, exact match first, then case-insensitive (unquoted
--- SQL identifiers are case-folded per engine; the stored name is canonical).
---@param list string[]
---@param name string
---@return string|nil
local function find_name(list, name)
  if vim.tbl_contains(list, name) then
    return name
  end
  local lower = name:lower()
  for _, item in ipairs(list) do
    if item:lower() == lower then
      return item
    end
  end
  return nil
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
