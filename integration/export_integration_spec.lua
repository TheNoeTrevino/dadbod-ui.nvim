-- High-fidelity export integration suite.
--
-- Unlike tests/export_spec.lua (which stubs the bridge + vim.system), this drives
-- the REAL export pipeline against REAL database servers: it runs the actual
-- adapter CLI (psql / mysql / sqlite3) against a seeded container, then compares
-- the exported bytes to a committed golden file. This is the only automated check
-- of the one seam the unit tests deliberately fake -- argv -> real CLI -> parse /
-- passthrough -> file bytes -- i.e. the T16 manual checklist, automated forever.
--
-- Not run by `make test` (it lives outside tests/). Driven by integration/run.sh,
-- which stands up the databases, seeds them, and sets the env vars below:
--   DBUI_IT_MODE       'check' (default) | 'record' (write goldens)
--   DBUI_IT_GOLDEN_DIR absolute path to integration/golden
--   DBUI_IT_{PG,MYSQL,MARIADB,SQLITE}_URL  per-adapter connection urls ('' = skip)

local export = require('dadbod-ui.export')
local adapters = require('dadbod-ui.export_adapters')
local config = require('dadbod-ui.config')

local MODE = vim.env.DBUI_IT_MODE or 'check'
local GOLDEN_DIR = vim.env.DBUI_IT_GOLDEN_DIR or (vim.fn.getcwd() .. '/integration/golden')

-- The shared query over the seeded `people` fixture; deterministic ordering so
-- the output bytes are stable.
local QUERY = 'SELECT id, name, note, amount FROM people ORDER BY id'
local SOURCE = 'people'

-- Every target format, plus the extension each golden file carries.
local FORMATS = { 'csv', 'tsv', 'json', 'markdown', 'html', 'xml', 'sql' }
local EXT = { csv = 'csv', tsv = 'tsv', json = 'json', markdown = 'md', html = 'html', xml = 'xml', sql = 'sql' }

-- The adapters under test. `scheme` feeds the capability matrix / extractor; the
-- url comes from the environment (empty => the adapter is skipped as pending).
local ADAPTERS = {
  { name = 'postgres', scheme = 'postgres', url = vim.env.DBUI_IT_PG_URL or '' },
  { name = 'mysql', scheme = 'mysql', url = vim.env.DBUI_IT_MYSQL_URL or '' },
  { name = 'mariadb', scheme = 'mysql', url = vim.env.DBUI_IT_MARIADB_URL or '' },
  { name = 'sqlite', scheme = 'sqlite', url = vim.env.DBUI_IT_SQLITE_URL or '' },
}

-- Byte-exact file IO (no newline munging -- goldens store exactly what the
-- pipeline produced, embedded newlines and all).
local function read_bytes(path)
  local fh = io.open(path, 'rb')
  if not fh then
    return nil
  end
  local data = fh:read('*a')
  fh:close()
  return data
end

local function write_bytes(path, data)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  local fh = assert(io.open(path, 'wb'))
  fh:write(data)
  fh:close()
end

-- Run the real export synchronously, capturing the bytes that WOULD be written
-- (via an injected writer) while using the real process runner + bridge.
local function run_export(adapter, fmt, prefer_native)
  local captured = { done = false }
  export.export({
    url = adapter.url,
    scheme = adapter.scheme,
    format = fmt,
    query = QUERY,
    source = SOURCE,
    path = '(captured)',
    prefer_native = prefer_native,
    format_opts = export.format_opts(config.defaults.results.export, fmt, adapter.scheme),
  }, {
    write = function(_, content)
      captured.content = content
      return true
    end,
    notify = {
      info = function(msg)
        captured.info = msg
        captured.done = true
      end,
      error = function(msg)
        captured.error = msg
        captured.done = true
      end,
    },
  })
  local ok = vim.wait(30000, function()
    return captured.done
  end, 50)
  assert(ok, string.format('%s/%s export timed out after 30s', adapter.name, fmt))
  assert(not captured.error, string.format('%s/%s export failed: %s', adapter.name, fmt, captured.error or ''))
  assert(captured.content ~= nil, string.format('%s/%s produced no content', adapter.name, fmt))
  return captured.content
end

-- Compare against (or, in record mode, write) the golden at `rel`.
local function assert_golden(rel, content)
  local path = string.format('%s/%s', GOLDEN_DIR, rel)
  if MODE == 'record' then
    write_bytes(path, content)
    return
  end
  local expected = read_bytes(path)
  assert(expected ~= nil, string.format('missing golden %s -- run `make test-integration-record` to create it', rel))
  assert.are.equal(expected, content)
end

for _, adapter in ipairs(ADAPTERS) do
  describe('export ' .. adapter.name, function()
    if adapter.url == '' then
      pending(adapter.name .. ' url not configured (set DBUI_IT_* / run via integration/run.sh)')
      return
    end

    for _, fmt in ipairs(FORMATS) do
      local native = adapters.is_native(adapter.scheme, fmt, true)

      -- Production path: prefer_native on. Native pairs pass the CLI output
      -- through verbatim; everything else runs the Lua formatter over the extract.
      it(string.format('%s (%s)', fmt, native and 'native passthrough' or 'lua formatter'), function()
        local content = run_export(adapter, fmt, true)
        assert_golden(string.format('%s/%s.%s', adapter.name, fmt, EXT[fmt]), content)
      end)

      -- For native-capable pairs, also validate the forced-formatter path
      -- (prefer_native=false) against the SAME real database, so both code paths
      -- are covered. Non-native formats already take this path above, so skip.
      if native then
        it(string.format('%s (lua formatter, prefer_native=false)', fmt), function()
          local content = run_export(adapter, fmt, false)
          assert_golden(string.format('%s/formatter/%s.%s', adapter.name, fmt, EXT[fmt]), content)
        end)
      end
    end
  end)
end
