# Integration suite

High-fidelity, end-to-end tests against **real database servers**. Where the
unit suite (`make test`) stubs the database bridge and `vim.system`, everything
under `integration/` drives the real pipeline - real adapter CLI → real server →
real parsing - organized as one spec package per feature:

```
export/    real CLI export, byte-diffed against committed golden files
```

(More packages - introspection, query, pagination, explain, table helpers - ride
the same harness; each spec family documents itself.)

The servers under test:

| Adapter    | Server (Docker)                          | Client CLI          | Tier |
|------------|------------------------------------------|---------------------|------|
| postgres   | `postgres:16`                            | `psql`              | default |
| mysql      | `mysql:8.4`                              | `mysql`/`mariadb`   | default |
| mariadb    | `mariadb:11`                             | `mysql`/`mariadb`   | default |
| sqlite     | *(none - a file)*                        | `sqlite3`           | default |
| clickhouse | `clickhouse/clickhouse-server:24.8`      | `clickhouse-client` | extra |
| mongodb    | `mongo:7`                                | `mongosh`           | extra |
| sqlserver  | `mcr.microsoft.com/mssql/server:2022`    | `sqlcmd`            | extra |

The **extra tier** is the compose profile `extra`, opted into with
`DBUI_IT_EXTRA=1 make test-integration`. Their seeding runs *inside* the
containers (the images ship their client), but the specs drive the **host**
CLI through dadbod, so an extra adapter's specs run only when that client is
on your PATH -- otherwise they report `pending`, never failed.

Not in the suite: **oracle** (the free container image is multi-GB with a
minutes-long first start, and `sqlplus` host installs are rare -- revisit if
oracle regressions actually bite) and **bigquery** (a cloud service; there is
no container to test against).

## One stack definition, one entry point

`integration/docker-compose.yml` is the **single definition** of the database
stack - pinned image tags, healthchecks, non-default ports (`5543x`/`5330x`) so
it never collides with databases you already run. The CI workflow deliberately
declares **no `services:` block**: it installs the client CLIs + Neovim and runs
the exact same `make test-integration` you run locally, so local and CI cannot
drift.

```sh
make test-integration          # check: fail on any golden mismatch / assertion
make test-integration-record   # record: (re)write the golden files
```

Requires on your PATH: `docker` (+ compose plugin), `nvim` (>= 0.12), `psql`,
`mysql` (or `mariadb`), `sqlite3`. `integration/run.sh` brings the servers up
with `docker compose`, waits for health, seeds them with the shared fixture
using the host clients, runs every `integration/**/*_spec.lua`, and tears the
servers down. `DBUI_IT_KEEP=1` leaves the containers running for fast re-runs.

The specs run under the **same mini.test runner as the unit suite**
(`tests/minit.lua`, spec files passed as argv) - one busted-style dialect, one
process, no extra test dependencies.

A golden change is a **deliberate output change** - review the diff (`git diff
integration/golden`) before committing a re-record.

## Layout

```
docker-compose.yml   THE stack definition (pinned tags, healthchecks, ports)
run.sh               orchestrator (compose up → seed → all specs → down)
seed/*.sql           one shared "nasty data" fixture per dialect (NULL, quotes,
                     commas, embedded newline, unicode, XML/HTML metachars)
export/export_spec.lua              real M.export, byte-exact golden diff
golden/<adapter>/<fmt>              production path (prefer_native on)
golden/<adapter>/formatter/<fmt>    forced Lua-formatter path (native pairs only)
```

## CI

`.github/workflows/integration.yml` is a thin caller: checkout, install client
CLIs + Neovim, `make test-integration`. Compose runs inside the runner - the
database containers are siblings of the job on the runner's Docker daemon,
which is supported on GitHub-hosted runners out of the box.

### Rehearsing CI locally with act (optional)

[`act`](https://github.com/nektos/act) is NOT required to contribute -
`make test-integration` is the suite. But to rehearse the workflow itself:

```sh
act workflow_dispatch -W .github/workflows/integration.yml \
  -P ubuntu-latest=catthehacker/ubuntu:act-latest
```

act mounts the host Docker socket into the job container by default, so the
compose-up inside `run.sh` talks to your host daemon exactly like CI's.

### Raspberry Pi / self-hosted

All images (`postgres:16`, `mysql:8.4`, `mariadb:11`) publish `linux/arm64`, and
the workflow's Neovim install step is arch-aware. Running all servers at once
wants ~1.5-2 GB free RAM; on a small Pi, point only some `DBUI_IT_*_URL` at live
servers (an unset url is reported as `pending`, not failed). Docker's local
image store persists the pulled images across runs - no cache configuration
needed.

## Known limitations this suite pinned down

- **LIMITATION-003 (client-dependent NULL under `--batch`).** Oracle's `mysql` client
  renders SQL NULL as `\N`; MariaDB's client renders it as the literal word `NULL`.
  The extractor maps **both** to the SQL-NULL sentinel, so a real string value of
  `\N`/`NULL` is indistinguishable from SQL NULL - the same empty-vs-NULL ambiguity
  class as CSV (LIMITATION-001). The goldens are recorded with the **MariaDB client**;
  CI pins `mariadb-client` to match, because the `--html`/`--xml` native passthrough is
  raw client bytes and differs between the two clients.
- **sqlite native `markdown` and `html` are not passthrough.** sqlite3's `-markdown`
  numeric-column alignment changed between releases (not reproducible across
  environments) and its `-html` emits a bare `<TR>` fragment. Both go through the Lua
  formatter instead (deterministic, uniform with the other adapters). sqlite native
  `-json` and `-csv` are stable and stay native.
