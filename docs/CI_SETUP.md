# CI setup

Maintainer-side notes for the integration suite's CI. Contributors never need
any of this -- the suite runs with nothing but docker
([integration/README.md](../integration/README.md)); this page covers the
runner-image publishing machinery, the one-time repository configuration, and
the trust model behind it.

## The pieces

- `.github/workflows/integration.yml` -- runs the suite on every code PR and
  on pushes to `main`. Token is read-only (`contents: read`,
  `packages: read`); the GHCR login is `continue-on-error`, so a token that
  cannot pull the image (fork PRs, private package) just means a local build.
- `.github/workflows/integration-runner.yml` -- publishes the runner image to
  GHCR. Triggers only on trunk pushes touching the Dockerfile (or the
  publishing machinery itself) and on manual dispatch -- **never from a PR**,
  so `packages: write` is only ever held by post-merge code.
- `integration/runner-image.sh` -- the single source of the image ref; the
  tag is a hash of `integration/Dockerfile`. `run.sh` (pull or build) and the
  publish workflow both call it, so they cannot disagree about which image
  they mean.

## Where the time goes

The suite itself is ~10s. Standing the stack up used to be ~57s of that, all
of it serial, so two things changed:

- **The servers and the runner image are prepared in parallel** (`run.sh`).
  They share nothing, so the image step hides inside the database pull +
  healthcheck wait.
- **The runner image is published, not rebuilt.** A normal run pulls the
  GHCR image in seconds instead of reinstalling every client from apt and
  GitHub releases.

Because the tag is content-addressed, none of this can serve you a stale
image: change a pinned client version and you are asking for a *different*
tag. When that tag has not been published yet -- a PR that edits the
Dockerfile, or an arm64 host, since the published image is amd64 -- `run.sh`
builds locally exactly as it always did. **Nothing here is required for the
suite to work**; it is only ever the difference between fast and slow. An
arm64 host builds the image once and then reuses it until the Dockerfile
changes.

Once the publish workflow is on the default branch, you can also run it from
the Actions tab against any branch (`workflow_dispatch`) to publish that
branch's image without waiting for a merge. GitHub only offers the dispatch
for workflows that exist on the default branch, so this does not work for the
PR that *adds* the workflow.

`DBUI_IT_RUNNER_IMAGE=<ref> make test-integration` points the suite at a
specific image: trying a candidate before publishing it, or pinning an older
runner to bisect a golden.

## Activating the fast path (one-time, after the publish workflow merges)

The workflow only publishes; the rest is repo/package settings in the GitHub
UI. In order:

1. **Actions tab → "integration runner image" → Run workflow.** The first
   publish; confirm the package appears and the run's summary shows the digest.
2. **Package settings** (`dadbod-ui.nvim/integration-runner`): set visibility
   **public** -- fork PR tokens cannot read a private package (if it stays
   private they still pass; they just build the image, at the old speed).
   Under *Manage Actions access* confirm only this repo is listed; that
   writer set is what the trust model below stands on.
3. **Repo Settings → Actions → General**: require approval for **all outside
   collaborators** (fork PRs run only after you look), and set the default
   workflow token permissions to **read-only** (workflows that need more, like
   the publish job, already declare it explicitly).

Nothing breaks while any of this is pending: `run.sh` falls back to building
the image locally, at the old speed.

## The trust model for the published image

The content-addressed tag prevents *staleness*: same Dockerfile, same tag, so
a client-version bump asks for a different image by construction. What it does
not provide is *integrity* -- a registry tag is a mutable pointer, and nothing
cryptographic ties what is stored under a tag to the Dockerfile that named it.

Two things carry that instead:

- **The writer set.** The only thing that can push to the package is the
  publish workflow's `GITHUB_TOKEN`, which exists only on trunk pushes and
  maintainer dispatch. Keep the package's Actions access restricted to this
  repo (step 2 above); widening it widens who an "existing tag" trusts.
- **The audit trail.** Every publish writes the digest it pushed to its job
  summary, so what a tag pointed to at any time is reconstructable from the
  run list.

The publish job skips when the tag already exists. That is what makes it
idempotent, but it also means a bad image under a tag would *stay* there --
another reason the writer set is the load-bearing part. To force a republish,
delete the tag from the package and dispatch the workflow.

## Conventions the workflows follow

- **Actions pinned by commit SHA** (with a trailing `# vX.Y.Z` comment), so
  what runs changes only when we change it. Bump deliberately.
- **`persist-credentials: false`** on every checkout -- nothing after checkout
  talks to the repo, so the token does not sit in `.git/config` for the rest
  of the job.
- **Secrets reach shells via `env`**, never `${{ }}` interpolation inside
  `run:` -- interpolation pastes the value into the command line, where it
  reaches argv.
- **Superseded PR runs are cancelled** (`concurrency` in `integration.yml`);
  runs on `main` never are.
