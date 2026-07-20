#!/usr/bin/env bash
# Prints the runner image reference. THE single place the name and tag are
# derived -- run.sh (which pulls or builds it) and
# .github/workflows/integration-runner.yml (which publishes it) both call this,
# so the two can never disagree about which tag they mean.
#
# The tag is a hash of the Dockerfile, which makes it content-addressed: bump a
# pinned client version and you are automatically asking for a different image,
# so a stale build can never be silently reused -- and the published tag for
# today's Dockerfile keeps working on older branches.
#
# This is only correct while the Dockerfile is the *whole* build input. It has
# no COPY/ADD from the build context (every tool is downloaded by digest-free
# but version-pinned URL), so hashing it alone covers everything. If you ever
# add a COPY here, hash the copied files too.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# sha256sum is coreutils (Linux); macOS ships shasum instead.
if command -v sha256sum >/dev/null 2>&1; then
  TAG="$(sha256sum "$HERE/Dockerfile" | cut -c1-12)"
else
  TAG="$(shasum -a 256 "$HERE/Dockerfile" | cut -c1-12)"
fi

# Lowercase: GHCR rejects uppercase in a repository name, and the org is
# TheNoeTrevino.
echo "ghcr.io/thenoetrevino/dadbod-ui.nvim/integration-runner:${TAG}"
