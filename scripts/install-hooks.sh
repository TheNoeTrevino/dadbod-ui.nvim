#!/bin/bash
# Install pre-commit hook for dadbod-ui.nvim

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get the git directory (handles worktrees)
GIT_DIR=$(git rev-parse --git-common-dir)

if [ ! -d "$GIT_DIR" ]; then
  echo "Error: Not in a git repository"
  exit 1
fi

HOOK_PATH="$GIT_DIR/hooks/pre-commit"

# Create the pre-commit hook
cat >"$HOOK_PATH" <<'EOF'
#!/bin/bash
# dadbod-ui-stylua-hook
# Format staged Lua files with stylua while preserving partial-hunk staging.

set -euo pipefail

if ! command -v stylua >/dev/null 2>&1; then
  echo "✗ stylua not found on PATH - install it (e.g. cargo install stylua, or your package manager)." >&2
  echo "  Bypass with: git commit --no-verify" >&2
  exit 1
fi

# Collect staged Lua files (NUL-delimited to survive odd paths).
mapfile -d '' STAGED < <(
  git diff --cached --name-only --diff-filter=ACMR -z |
    grep -zE '\.lua$' || true
)

if [ "${#STAGED[@]}" -eq 0 ]; then
  exit 0
fi

# Detect a temp-index commit (git commit <path>, --only, some IDE flows). In
# that mode, `git add` inside the hook updates the *real* index, not the one
# being committed - meaning our formatting would not end up in the commit.
if [ -n "${GIT_INDEX_FILE:-}" ] && [ "$GIT_INDEX_FILE" != "$(git rev-parse --git-path index)" ]; then
  echo "✗ stylua hook: detected pathspec/--only commit (temp index)." >&2
  echo "  Re-running this hook here would silently drop the formatting." >&2
  echo "  Stage your files explicitly (git add) and commit without a pathspec," >&2
  echo "  or bypass with --no-verify if you know what you're doing." >&2
  exit 1
fi

# Capture any UNSTAGED hunks in the staged files as a patch (empty if there are
# none), then reset those files to their staged (index) content. This is what
# lets partial-hunk staging survive: stylua only ever sees the staged content,
# and the unstaged hunks are re-applied to the working tree afterward. Unlike
# `git stash`, a plain diff/apply re-applies cleanly whenever the unstaged edits
# don't overlap the lines stylua rewrote - no spurious merge conflicts.
# --no-ext-diff: ignore external diff drivers so the patch is apply-able.
UNSTAGED_PATCH="$(mktemp)"
git diff --no-ext-diff --no-color -- "${STAGED[@]}" >"$UNSTAGED_PATCH"

cleanup() {
  # Re-apply the unstaged hunks to the working tree (index is left untouched,
  # so they stay unstaged). Runs as the EXIT trap on every exit path, aborts
  # included.
  if [ -s "$UNSTAGED_PATCH" ]; then
    # Strict apply first (exact context). If the unstaged hunk sits within a few
    # lines of a reformatted region its context won't match, so fall back to a
    # tolerant apply (-C1 needs only one line of context). Both touch the working
    # tree ONLY - never the index - so the commit is still built from the
    # formatted staged content.
    if ! git apply --whitespace=nowarn -- "$UNSTAGED_PATCH" 2>/dev/null &&
      ! git apply --recount -C1 --whitespace=nowarn -- "$UNSTAGED_PATCH" 2>/dev/null; then
      recovery="$(git rev-parse --git-dir)/stylua-hook-unstaged.patch"
      cp "$UNSTAGED_PATCH" "$recovery"
      echo "" >&2
      echo "⚠ stylua hook: your unstaged changes overlap the lines stylua reformatted," >&2
      echo "  so they could not be re-applied automatically. They are NOT lost -" >&2
      echo "  the patch was saved to:" >&2
      echo "    $recovery" >&2
      echo "  Re-apply (and resolve any rejects) with:" >&2
      echo "    git apply --3way \"$recovery\"" >&2
    fi
  fi
  rm -f "$UNSTAGED_PATCH"
  # Always succeed: this runs as the EXIT trap, and a non-zero status here
  # would propagate as the hook's exit code and wrongly abort the commit.
  return 0
}
trap cleanup EXIT

if [ -s "$UNSTAGED_PATCH" ]; then
  # Drop unstaged hunks from the working tree so it mirrors the index exactly.
  git checkout -- "${STAGED[@]}"
fi

echo "Formatting ${#STAGED[@]} staged Lua file(s) with stylua..."

# Snapshot hashes in one git invocation so we only re-stage files stylua
# actually rewrote. --stdin-paths reads newline-delimited paths; paths with
# embedded newlines (vanishingly rare) would break this.
mapfile -t BEFORE < <(printf '%s\n' "${STAGED[@]}" | git hash-object --stdin-paths)

stylua -- "${STAGED[@]}"

mapfile -t AFTER < <(printf '%s\n' "${STAGED[@]}" | git hash-object --stdin-paths)

TO_ADD=()
for i in "${!STAGED[@]}"; do
  if [ "${BEFORE[$i]}" != "${AFTER[$i]}" ]; then
    TO_ADD+=("${STAGED[$i]}")
    echo "  formatted: ${STAGED[$i]}"
  fi
done

if [ "${#TO_ADD[@]}" -eq 0 ]; then
  echo "✓ already formatted"
else
  git add -- "${TO_ADD[@]}"
  echo "✓ formatted ${#TO_ADD[@]} file(s)"
fi

# After formatting, if nothing remains staged vs HEAD, abort instead of
# letting an empty commit slip through.
if git diff --cached --quiet; then
  echo "" >&2
  echo "✗ Nothing to commit after formatting - staged changes were only formatting differences." >&2
  echo "  Aborting to avoid an empty commit. Use --no-verify if you really want one." >&2
  exit 1
fi
EOF

# Make the hook executable
chmod +x "$HOOK_PATH"

echo -e "${GREEN}✓ Pre-commit hook installed successfully${NC}"
echo ""
echo "The hook will:"
echo "  • Format staged Lua files with stylua (uses ./stylua.toml)"
echo "  • Re-stage only the files stylua actually rewrote"
echo "  • Preserve partial-hunk staging (git add -p safe)"
echo ""
echo "Usage:"
echo "  • Normal commit: ${YELLOW}git commit${NC}"
echo "  • Bypass hook: ${YELLOW}git commit --no-verify${NC}"
echo "  • Manual format: ${YELLOW}stylua <file>${NC}"
