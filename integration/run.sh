#!/usr/bin/env bash
# Integration harness: stand up the database servers in Docker (the compose file
# is the SINGLE definition of the stack -- CI runs this same script), seed them
# with the shared fixture using the host client CLIs, then run every
# integration/**/*_spec.lua against the live servers under the same mini.test
# runner the unit suite uses (tests/minit.lua).
#
#   integration/run.sh            # check mode: fail on any golden mismatch
#   integration/run.sh record     # record mode: (re)write every golden
#
# Connection details come from env vars (defaults match docker-compose.yml).
# Point the DBUI_IT_*_HOST/_PORT overrides at servers you already run:
#   DBUI_IT_{PG,MYSQL,MARIADB}_HOST / _PORT
#   DBUI_IT_KEEP=1   leave the containers running on exit (faster re-runs).
#   DBUI_IT_EXTRA=1  also stand up the `extra` compose profile (clickhouse,
#                    mongodb, sqlserver). Seeding runs inside those containers;
#                    each adapter's specs run only when the matching HOST
#                    client CLI (clickhouse-client / mongosh / sqlcmd) exists,
#                    because dadbod drives the host CLI.
set -euo pipefail

MODE="${1:-check}"
if [[ "$MODE" != "check" && "$MODE" != "record" ]]; then
  echo "usage: $0 [check|record]" >&2
  exit 2
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
COMPOSE=(docker compose -f "$HERE/docker-compose.yml")
if [[ "${DBUI_IT_EXTRA:-0}" == "1" ]]; then
  COMPOSE+=(--profile extra)
fi

# Connection details (defaults match docker-compose.yml's published ports).
PG_HOST="${DBUI_IT_PG_HOST:-127.0.0.1}"; PG_PORT="${DBUI_IT_PG_PORT:-55433}"
MY_HOST="${DBUI_IT_MYSQL_HOST:-127.0.0.1}"; MY_PORT="${DBUI_IT_MYSQL_PORT:-53306}"
MA_HOST="${DBUI_IT_MARIADB_HOST:-127.0.0.1}"; MA_PORT="${DBUI_IT_MARIADB_PORT:-53307}"

export DBUI_IT_MODE="$MODE"
export DBUI_IT_GOLDEN_DIR="$HERE/golden"
export DBUI_IT_PG_URL="postgres://dbui:dbui@${PG_HOST}:${PG_PORT}/dbui"
export DBUI_IT_MYSQL_URL="mysql://dbui:dbui@${MY_HOST}:${MY_PORT}/dbui"
export DBUI_IT_MARIADB_URL="mysql://dbui:dbui@${MA_HOST}:${MA_PORT}/dbui"

SQLITE_TMP="$(mktemp -d)"
export DBUI_IT_SQLITE_URL="sqlite:${SQLITE_TMP}/dbui.db"

cleanup() {
  rm -rf "$SQLITE_TMP"
  if [[ "${DBUI_IT_KEEP:-0}" != "1" ]]; then
    "${COMPOSE[@]}" down -v >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

echo "==> databases"
"${COMPOSE[@]}" up -d --wait

echo "==> seeding"
# The mysql-family client is `mysql` on Arch/macOS and may be `mariadb` on some
# distros (Debian/Ubuntu's default-mysql-client). Both talk to either server.
MYSQL_BIN="$(command -v mysql || command -v mariadb || true)"
[[ -n "$MYSQL_BIN" ]] || { echo "no mysql/mariadb client on PATH" >&2; exit 1; }

PGPASSWORD=dbui psql -h "$PG_HOST" -p "$PG_PORT" -U dbui -d dbui -v ON_ERROR_STOP=1 -q -f "$HERE/seed/postgres.sql"
"$MYSQL_BIN" --host="$MY_HOST" --port="$MY_PORT" -u dbui -pdbui dbui <"$HERE/seed/mysql.sql"
"$MYSQL_BIN" --host="$MA_HOST" --port="$MA_PORT" -u dbui -pdbui dbui <"$HERE/seed/mysql.sql"
sqlite3 "${SQLITE_TMP}/dbui.db" <"$HERE/seed/sqlite.sql"

if [[ "${DBUI_IT_EXTRA:-0}" == "1" ]]; then
  echo "==> seeding extras (inside the containers)"
  "${COMPOSE[@]}" exec -T clickhouse clickhouse-client --user dbui --password dbui --database dbui -n <"$HERE/seed/clickhouse.sql"
  "${COMPOSE[@]}" exec -T mongodb mongosh --quiet dbui <"$HERE/seed/mongodb.js"
  "${COMPOSE[@]}" exec -T sqlserver /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P DbuiPass1 -b <"$HERE/seed/sqlserver.sql"

  # The specs drive the HOST client through dadbod: export an url only when
  # that client exists, otherwise the adapter's specs report pending.
  if command -v clickhouse-client >/dev/null || command -v clickhouse >/dev/null; then
    export DBUI_IT_CH_URL="clickhouse://dbui:dbui@127.0.0.1:59000/dbui"
  fi
  if command -v mongosh >/dev/null || command -v mongo >/dev/null; then
    export DBUI_IT_MONGO_URL="mongodb://127.0.0.1:57017/dbui"
  fi
  if command -v sqlcmd >/dev/null; then
    export DBUI_IT_MSSQL_URL="sqlserver://sa:DbuiPass1@127.0.0.1:51433/dbui"
  fi
fi

echo "==> running integration specs ($MODE)"
cd "$ROOT"
# Same runner as the unit suite (lazy.minit + mini.test, one Neovim process):
# tests/minit.lua collects the spec files passed as argv instead of globbing
# tests/, so the integration tree needs no runner of its own.
mapfile -t SPECS < <(find integration -name '*_spec.lua' | sort)
nvim -l tests/minit.lua --minitest "${SPECS[@]}"
