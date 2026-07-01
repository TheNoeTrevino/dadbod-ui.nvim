# Export integration suite

High-fidelity, end-to-end tests for native CLI result export (`specs/native-export.md`).
Where `tests/export_spec.lua` stubs the database bridge and `vim.system`, this suite
drives the **real** pipeline — real adapter CLI → real server → parse/passthrough →
file bytes — and compares the output to committed **golden files**. It is the
automated form of the T16 manual verification checklist.

It covers every adapter × every format, plus the forced-formatter path
(`prefer_native = false`) for each format the CLI can emit natively:

| Adapter  | Server (Docker)     | Client CLI        |
|----------|---------------------|-------------------|
| postgres | `postgres:16`       | `psql`            |
| mysql    | `mysql:8.4`         | `mysql`/`mariadb` |
| mariadb  | `mariadb:11`        | `mysql`/`mariadb` |
| sqlite   | *(none — a file)*   | `sqlite3`         |

## Running locally (host runner)

The databases run in Docker; **Neovim and the client CLIs run on your host**.

```sh
make test-integration          # check: fail on any golden mismatch
make test-integration-record   # record: (re)write the golden files
```

Requires on your PATH: `docker` (+ compose plugin), `nvim` (≥ 0.10, for `vim.system`),
`psql`, `mysql` (or `mariadb`), `sqlite3`. `integration/run.sh` brings the servers up
with `docker compose`, waits for health, seeds them with the shared fixture using the
host clients, runs the spec, and tears the servers down.

A golden change is a **deliberate output change** — review the diff (`git diff
integration/golden`) before committing a re-record.

## Layout

```
docker-compose.yml   the three DB servers (pinned tags, healthchecks, 127.0.0.1:5543x/5330x)
seed/*.sql           one shared "nasty data" fixture per dialect (NULL, quotes, commas,
                     embedded newline, unicode, XML/HTML metachars, nullable numeric)
export_integration_spec.lua   the plenary spec (real M.export, byte-exact golden diff)
golden/<adapter>/<fmt>              production path (prefer_native on)
golden/<adapter>/formatter/<fmt>    forced Lua-formatter path (native pairs only)
run.sh               orchestrator (compose up → seed → spec → down)
```

## CI

`.github/workflows/integration.yml` runs the same suite. The job runs **inside a
container** so the DB services are reachable by their service hostname — which makes
the workflow behave identically under [`act`](https://github.com/nektos/act) (always
containerised) and on real GitHub-hosted runners. `run.sh` reads the connection
host/port from env (`DBUI_IT_{PG,MYSQL,MARIADB}_HOST/_PORT`) and `DBUI_IT_NO_COMPOSE=1`
skips compose (the CI service containers provide the DBs).

Run it locally with act:

```sh
act workflow_dispatch -W .github/workflows/integration.yml \
  -P ubuntu-latest=catthehacker/ubuntu:act-latest
```

### Raspberry Pi / self-hosted `act`

Yes, this runs on a Pi (or any arm64 self-hosted box). All four images
(`ubuntu:24.04`, `postgres:16`, `mysql:8.4`, `mariadb:11`) publish `linux/arm64`, and
the Neovim install step is arch-aware (`nvim-linux-arm64.tar.gz`). Notes:

- Use a **64-bit** OS. Point `act` at an arm64 runner image
  (`-P ubuntu-latest=catthehacker/ubuntu:act-latest` resolves per-arch), or add a
  `~/.actrc` with that `-P` line so you can just run `act`.
- Running postgres + mysql + mariadb at once wants ~1.5–2 GB free RAM. On a small Pi,
  narrow the matrix by pointing only some `DBUI_IT_*_URL` at live servers (an unset url
  is reported as `pending`, not failed).

### Caching (so it isn't slow every run)

The expensive artifacts are the **Docker images** (the three DB servers + the runner
image). Docker's local image store persists them across runs automatically — on a
persistent host or Pi they are pulled **once**, not per run. That is the caching that
matters, and it needs no configuration.

There is intentionally **no `actions/cache` step**: it is a Node action and the bare
container has no Node, which breaks `act`. What remains per run is a small apt install
(~8 s) plus two shallow `git clone`s into `.deps` (a few seconds). If you want to
eliminate even those on a Pi, bake a custom runner image with the tools + `.deps`
preinstalled and point the workflow's `container.image` at it.

## Known limitations this suite pinned down

- **LIMITATION-003 (client-dependent NULL under `--batch`).** Oracle's `mysql` client
  renders SQL NULL as `\N`; MariaDB's client renders it as the literal word `NULL`.
  The extractor maps **both** to the SQL-NULL sentinel, so a real string value of
  `\N`/`NULL` is indistinguishable from SQL NULL — the same empty-vs-NULL ambiguity
  class as CSV (LIMITATION-001). The goldens are recorded with the **MariaDB client**;
  CI pins `mariadb-client` to match, because the `--html`/`--xml` native passthrough is
  raw client bytes and differs between the two clients.
- **sqlite native `markdown` and `html` are not passthrough.** sqlite3's `-markdown`
  numeric-column alignment changed between releases (not reproducible across
  environments) and its `-html` emits a bare `<TR>` fragment. Both go through the Lua
  formatter instead (deterministic, uniform with the other adapters). sqlite native
  `-json` and `-csv` are stable and stay native.
