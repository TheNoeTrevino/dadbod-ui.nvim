# Integration suite

High-fidelity, end-to-end tests against **real database servers**. Where the
unit suite (`make test`) stubs the database bridge and `vim.system`, everything
under `integration/` drives the real pipeline - real adapter CLI → real server →
real parsing - organized as one spec package per feature:

```
export/          real CLI export, byte-diffed against committed golden files
introspection/   expand a live connection; seeded schemas/tables/routines land
query/           execution, pagination, explain, table helpers
mongodb/         the (non-SQL) mongodb surface: collections + find()
```

The servers under test:

| Adapter    | Server (Docker)                          | Client CLI (in the runner image) | Tier |
|------------|------------------------------------------|----------------------------------|------|
| postgres   | `postgres:16`                            | `psql`                           | default |
| mysql      | `mysql:8.4`                              | `mariadb`                        | default |
| mariadb    | `mariadb:11`                             | `mariadb`                        | default |
| sqlite     | *(none - a file)*                        | `sqlite3`                        | default |
| clickhouse | `clickhouse/clickhouse-server:24.8`      | `clickhouse`                     | extra |
| mongodb    | `mongo:7`                                | `mongosh`                        | extra |
| sqlserver  | `mcr.microsoft.com/mssql/server:2022`    | `sqlcmd`                         | extra |

The **extra tier** is the compose profile `extra`, opted into with
`DBUI_IT_EXTRA=1 make test-integration`. Nothing extra to install -- the
runner image already carries every client.

Not in the suite: **oracle** (the free container image is multi-GB with a
minutes-long first start, and `sqlplus` host installs are rare -- revisit if
oracle regressions actually bite) and **bigquery** (a cloud service; there is
no container to test against).

## Docker is the only requirement

`integration/docker-compose.yml` is the **single definition** of everything -
pinned image tags, healthchecks, non-default ports (`5543x`/`5330x`) so it never
collides with databases you already run, **and the test runner itself**.

dadbod does not speak the database wire protocols: it shells out to the client
CLI (`psql`, `mariadb`, `mongosh`, ...), so those binaries must live wherever
Neovim runs. Rather than making every contributor install six database clients,
the `runner` service (see `Dockerfile`) is an image with Neovim + all of them,
and the repo mounted at `/work`. So:

```sh
make test-integration          # check: fail on any golden mismatch / assertion
make test-integration-record   # record: (re)write the golden files
```

...needs **only `docker` (+ the compose plugin)**. Nothing else - no Neovim, no
clients, no `.deps`. `integration/run.sh` brings the servers up, waits for
health, then runs `integration/run-suite.sh` inside the runner container (which
seeds every server and runs every `integration/**/*_spec.lua`), and tears the
stack down. `DBUI_IT_KEEP=1` leaves the servers up for fast re-runs.

Because the runner is a container, CI and local runs are the *same* execution
environment rather than two parallel ones - the client versions that produce
the golden bytes are pinned in the image, not in whatever each machine
installed.

The specs run under the **same mini.test runner as the unit suite**
(`tests/minit.lua`, spec files passed as argv) - one busted-style dialect, one
process, no extra test dependencies.

A golden change is a **deliberate output change** - review the diff (`git diff
integration/golden`) before committing a re-record.

## Layout

```
docker-compose.yml   THE stack definition (servers + the runner service)
Dockerfile           the runner image: Neovim + every client CLI (pinned)
run.sh               host side: compose lifecycle (up → run runner → down)
run-suite.sh         container side: seed every server → run every spec
seed/*               one shared "nasty data" fixture per dialect (NULL, quotes,
                     commas, embedded newline, unicode, XML/HTML metachars)
helper.lua           shared spec plumbing (real sessions, waits, dialect quirks)
<package>/*_spec.lua the specs themselves
golden/              export goldens: <adapter>/<fmt> is the production path
                     (prefer_native on), <adapter>/formatter/<fmt> the forced
                     Lua-formatter path (native pairs only)
```

## CI

`.github/workflows/integration.yml` installs **nothing**: checkout, then
`make test-integration`. Everything it needs is in the compose stack. Run the
extra adapters from the Actions tab via `workflow_dispatch` (the `extra` input).

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

All server images publish `linux/arm64`, and every download in the runner
`Dockerfile` is arch-aware, so the suite builds and runs on arm64 (a Pi, or
Apple silicon). Running all servers at once wants ~1.5-2 GB free RAM; the
default tier alone is much lighter than `DBUI_IT_EXTRA=1` (sqlserver especially).
Docker's local image store persists the pulled images and the built runner layer
across runs - no cache configuration needed.

Every tool in the runner image is fetched from **GitHub releases**, including
clickhouse and mongosh: their vendor download hosts fail TLS verification from
inside a container on networks with a proxy CA, while github.com is reachable
anywhere Docker can pull images.

## Known limitations this suite pinned down

- **LIMITATION-003 (client-dependent NULL under `--batch`).** Oracle's `mysql` client
  renders SQL NULL as `\N`; MariaDB's client renders it as the literal word `NULL`.
  The extractor maps **both** to the SQL-NULL sentinel, so a real string value of
  `\N`/`NULL` is indistinguishable from SQL NULL - the same empty-vs-NULL ambiguity
  class as CSV (LIMITATION-001). The goldens are recorded with the **MariaDB client**;
  the runner image ships `mariadb-client` (not Oracle's), which is what keeps the
  golden bytes reproducible everywhere -- the `--html`/`--xml` native passthrough is
  raw client bytes and differs between the two clients.
- **Row counting needs a header rule or a row-count footer.** clickhouse's bare
  TabSeparated output has neither, so dadbod-ui cannot count result rows for it
  -- which means the pagination last-page guard (`b:dbui_page.last`) never
  engages and `]` will keep stepping into empty pages. Pre-existing, unrelated
  to pagination itself; `integration/query/pagination_spec.lua` asserts the
  guard only for adapters where row counting works (`counts_rows`).
- **sqlite native `markdown` and `html` are not passthrough.** sqlite3's `-markdown`
  numeric-column alignment changed between releases (not reproducible across
  environments) and its `-html` emits a bare `<TR>` fragment. Both go through the Lua
  formatter instead (deterministic, uniform with the other adapters). sqlite native
  `-json` and `-csv` are stable and stay native.
