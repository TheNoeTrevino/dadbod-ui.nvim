#!/usr/bin/env bash
# Runs INSIDE the runner container (see Dockerfile): seed every live server
# with the shared fixture, then run every integration/**/*_spec.lua against
# them under the same mini.test runner the unit suite uses.
#
# Every client CLI is present in the image, so seeding and the specs take one
# code path -- no "is this client installed?" branching. Server hosts/ports
# arrive as DBUI_IT_*_HOST/_PORT from the compose service definition.
#
# Not meant to be run by hand: `integration/run.sh` (or `make
# test-integration`) owns the compose lifecycle and invokes this.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MODE="${DBUI_IT_MODE:-check}"

export DBUI_IT_GOLDEN_DIR="$HERE/golden"
export DBUI_IT_PG_URL="postgres://dbui:dbui@${DBUI_IT_PG_HOST}:${DBUI_IT_PG_PORT}/dbui"
export DBUI_IT_MYSQL_URL="mysql://dbui:dbui@${DBUI_IT_MYSQL_HOST}:${DBUI_IT_MYSQL_PORT}/dbui"
# mariadb:// (not mysql://): dadbod has a native mariadb adapter using the
# same client binary/flags, and dadbod-ui's mariadb spec carries capabilities
# the mysql one doesn't (ANALYZE FORMAT=JSON for the explain tree) -- the
# suite must exercise the adapter the scheme actually selects.
export DBUI_IT_MARIADB_URL="mariadb://dbui:dbui@${DBUI_IT_MARIADB_HOST}:${DBUI_IT_MARIADB_PORT}/dbui"

SQLITE_TMP="$(mktemp -d)"
trap 'rm -rf "$SQLITE_TMP"' EXIT
export DBUI_IT_SQLITE_URL="sqlite:${SQLITE_TMP}/dbui.db"

echo "==> seeding"
# client-min-messages=warning: the seeds are idempotent (DROP ... IF EXISTS),
# so psql's NOTICEs about absent objects are pure noise on a fresh stack.
PGPASSWORD=dbui PGOPTIONS='--client-min-messages=warning' psql -h "$DBUI_IT_PG_HOST" -p "$DBUI_IT_PG_PORT" -U dbui -d dbui \
  -v ON_ERROR_STOP=1 -q -f "$HERE/seed/postgres.sql"
mariadb --host="$DBUI_IT_MYSQL_HOST" --port="$DBUI_IT_MYSQL_PORT" -u dbui -pdbui dbui <"$HERE/seed/mysql.sql"
mariadb --host="$DBUI_IT_MARIADB_HOST" --port="$DBUI_IT_MARIADB_PORT" -u dbui -pdbui dbui <"$HERE/seed/mysql.sql"
sqlite3 "${SQLITE_TMP}/dbui.db" <"$HERE/seed/sqlite.sql"

if [[ "${DBUI_IT_EXTRA:-0}" == "1" ]]; then
  echo "==> seeding extras"
  clickhouse client --host "$DBUI_IT_CH_HOST" --port "$DBUI_IT_CH_PORT" \
    --user dbui --password dbui --database dbui -n <"$HERE/seed/clickhouse.sql"
  mongosh --quiet "mongodb://${DBUI_IT_MONGO_HOST}:${DBUI_IT_MONGO_PORT}/dbui" <"$HERE/seed/mongodb.js"
  sqlcmd -C -S "${DBUI_IT_MSSQL_HOST},${DBUI_IT_MSSQL_PORT}" -U sa -P DbuiPass1 -b -i "$HERE/seed/sqlserver.sql"

  export DBUI_IT_CH_URL="clickhouse://dbui:dbui@${DBUI_IT_CH_HOST}:${DBUI_IT_CH_PORT}/dbui"
  export DBUI_IT_MONGO_URL="mongodb://${DBUI_IT_MONGO_HOST}:${DBUI_IT_MONGO_PORT}/dbui"
  export DBUI_IT_MSSQL_URL="sqlserver://sa:DbuiPass1@${DBUI_IT_MSSQL_HOST}:${DBUI_IT_MSSQL_PORT}/dbui"
fi

echo "==> running integration specs ($MODE)"
cd "$ROOT"
# Same entry point as the unit suite (scripts/test -> lazy.minit + mini.test,
# one Neovim process): it takes spec paths as argv, so the integration tree
# needs no runner of its own -- and inherits the output filtering.
mapfile -t SPECS < <(find integration -name '*_spec.lua' | sort)
./scripts/test "${SPECS[@]}"
