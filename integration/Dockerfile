# The integration test runner: Neovim plus EVERY database client CLI the
# adapters shell out to. dadbod does not speak the database wire protocols --
# it spawns the client binary as a subprocess -- so the clients must live
# wherever Neovim runs. Putting them in this image is what makes `docker` the
# ONLY requirement to run the suite, locally and in CI alike.
#
# Pinned versions keep the recorded goldens reproducible: a client upgrade can
# change output bytes, so bump deliberately and re-record.
FROM ubuntu:24.04

ARG NVIM_VERSION=v0.12.3
ARG MONGOSH_VERSION=2.3.1
ARG SQLCMD_VERSION=1.8.2
# Matches the clickhouse-server tag in docker-compose.yml (24.8 LTS).
ARG CLICKHOUSE_VERSION=24.8.14.39

ENV DEBIAN_FRONTEND=noninteractive

# postgres + mysql/mariadb + sqlite clients from apt.
#
# mariadb-client (NOT Oracle's mysql-client): the golden files are recorded
# with the MariaDB client, whose --batch/--html/--xml output differs from
# Oracle's for NULL. Both talk to either server.
RUN apt-get update \
  && apt-get install -y --no-install-recommends \
  ca-certificates curl git make tar xz-utils bzip2 \
  postgresql-client mariadb-client sqlite3 \
  && rm -rf /var/lib/apt/lists/*

# Neovim, clickhouse, mongosh and sqlcmd are all single-binary/tarball installs
# -- no extra apt repos, and each is arch-aware (the suite runs on arm64 too,
# e.g. a Raspberry Pi or Apple silicon).
#
# Every download comes from GitHub releases, deliberately: vendor download
# hosts (clickhouse.com, downloads.mongodb.com) fail TLS verification from
# inside a container on networks with a proxy CA, while github.com is reachable
# anywhere Docker itself can pull images.
RUN set -eux; \
  case "$(uname -m)" in \
  x86_64)  NARCH=linux-x86_64; GOARCH=amd64; MARCH=x64 ;; \
  aarch64|arm64) NARCH=linux-arm64; GOARCH=arm64; MARCH=arm64 ;; \
  *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;; \
  esac; \
  \
  curl -fsSL -o /tmp/nvim.tar.gz \
  "https://github.com/neovim/neovim/releases/download/${NVIM_VERSION}/nvim-${NARCH}.tar.gz"; \
  tar -C /opt -xzf /tmp/nvim.tar.gz; \
  ln -sf "/opt/nvim-${NARCH}/bin/nvim" /usr/local/bin/nvim; \
  \
  curl -fsSL -o /tmp/clickhouse.tgz \
  "https://github.com/ClickHouse/ClickHouse/releases/download/v${CLICKHOUSE_VERSION}-lts/clickhouse-common-static-${CLICKHOUSE_VERSION}-${GOARCH}.tgz"; \
  tar -C /tmp -xzf /tmp/clickhouse.tgz; \
  mv "/tmp/clickhouse-common-static-${CLICKHOUSE_VERSION}/usr/bin/clickhouse" /usr/local/bin/clickhouse; \
  \
  curl -fsSL -o /tmp/mongosh.tgz \
  "https://github.com/mongodb-js/mongosh/releases/download/v${MONGOSH_VERSION}/mongosh-${MONGOSH_VERSION}-linux-${MARCH}.tgz"; \
  tar -C /tmp -xzf /tmp/mongosh.tgz; \
  mv "/tmp/mongosh-${MONGOSH_VERSION}-linux-${MARCH}/bin/mongosh" /usr/local/bin/mongosh; \
  \
  curl -fsSL -o /tmp/sqlcmd.tar.bz2 \
  "https://github.com/microsoft/go-sqlcmd/releases/download/v${SQLCMD_VERSION}/sqlcmd-linux-${GOARCH}.tar.bz2"; \
  tar -C /usr/local/bin -xjf /tmp/sqlcmd.tar.bz2 sqlcmd; \
  \
  rm -rf /tmp/*; \
  nvim --version | head -1

WORKDIR /work
