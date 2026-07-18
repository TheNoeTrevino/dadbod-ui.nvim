#!/usr/bin/env bash
# Integration harness. Docker is the ONLY thing you need installed: the
# database servers AND the test runner (Neovim + every client CLI) are all
# containers defined in docker-compose.yml -- the single definition of the
# stack, used identically by contributors and by CI.
#
#   integration/run.sh            # check mode: fail on any golden mismatch
#   integration/run.sh record     # record mode: (re)write every golden
#
#   DBUI_IT_KEEP=1   leave the servers running on exit (faster re-runs).
#   DBUI_IT_EXTRA=1  also stand up the `extra` profile (clickhouse, mongodb,
#                    sqlserver) and run their specs.
#
# The work itself happens in integration/run-suite.sh, inside the runner
# container (seeding + the specs); this script owns the compose lifecycle.
set -euo pipefail

MODE="${1:-check}"
if [[ "$MODE" != "check" && "$MODE" != "record" ]]; then
  echo "usage: $0 [check|record]" >&2
  exit 2
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE=(docker compose -f "$HERE/docker-compose.yml")
SERVERS=(postgres mysql mariadb)
if [[ "${DBUI_IT_EXTRA:-0}" == "1" ]]; then
  COMPOSE+=(--profile extra)
  SERVERS+=(clickhouse mongodb sqlserver)
fi

export DBUI_IT_MODE="$MODE"
export DBUI_IT_EXTRA="${DBUI_IT_EXTRA:-0}"

cleanup() {
  if [[ "${DBUI_IT_KEEP:-0}" != "1" ]]; then
    # `down` without -v: the seeds are idempotent, so keeping the database
    # volumes costs nothing and keeps the test-deps volume (the thing that
    # makes re-runs fast) intact. DBUI_IT_CLEAN=1 wipes everything.
    if [[ "${DBUI_IT_CLEAN:-0}" == "1" ]]; then
      "${COMPOSE[@]}" down -v >/dev/null 2>&1 || true
    else
      "${COMPOSE[@]}" down >/dev/null 2>&1 || true
    fi
  fi
}
trap cleanup EXIT

echo "==> databases"
"${COMPOSE[@]}" up -d --wait "${SERVERS[@]}"

echo "==> runner"
# --user keeps files the suite writes into the mounted repo (.tests/) owned by
# the invoking user rather than root.
"${COMPOSE[@]}" run --rm --build \
  --user "$(id -u):$(id -g)" \
  runner integration/run-suite.sh
