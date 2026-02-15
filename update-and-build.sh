#!/usr/bin/env bash
set -euo pipefail

# update-and-build.sh
#
# This repo is a thin wrapper that stores local patches, and builds an upstream
# OpenCode checkout in a *separate git worktree*.
#
# Why:
# - Avoids dirty working tree / branch checkout failures on this wrapper repo
# - Keeps a stable directory that always contains a built OpenCode binary
# - Allows ~/.opencode/bin/opencode to symlink directly into this repo

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAM_URL_DEFAULT="https://github.com/anomalyco/opencode.git"
OPENCODE_DIR="$REPO_DIR/opencode"
PATCH_DIR="$REPO_DIR/patches"
LOG_DIR="$REPO_DIR/logs"
RUN_ID="$(date +%Y%m%d-%H%M%S)"

BIN_LINK_DIR="$HOME/.opencode/bin"
BIN_LINK_PATH="$BIN_LINK_DIR/opencode"

mkdir -p "$LOG_DIR"

print_conflict_snippets() {
  local file="$1"
  local context="${2:-5}"

  if [[ ! -f "$file" ]]; then
    echo "(missing file: $file)"
    return
  fi

  local marker_lines
  marker_lines="$(grep -n -E '^(<<<<<<<|=======|>>>>>>>)' "$file" 2>/dev/null | cut -d: -f1 | tr '\n' ' ' || true)"
  if [[ -z "$marker_lines" ]]; then
    echo "(no conflict markers found)"
    return
  fi

  for ln in $marker_lines; do
    local start=$((ln - context))
    local end=$((ln + context))
    if (( start < 1 )); then start=1; fi

    echo
    echo "---- lines ${start}-${end} (around ${ln}) ----"
    sed -n "${start},${end}p" "$file" | nl -ba -w4 -s': ' -v "$start"
  done
}

write_patch_failure_report() {
  local stage="$1"        # e.g., "apply" or "apply --3way"
  local patch="$2"        # patch path
  local stderr_file="$3"  # captured stderr

  local report="$LOG_DIR/patch-failure_${LATEST_TAG}_${RUN_ID}_$(basename "$patch" .patch).md"

  {
    echo "# Patch failure report (opencode-custom)"
    echo
    echo "- time: $(date)"
    echo "- repo: $REPO_DIR"
    echo "- worktree: $OPENCODE_DIR"
    echo "- upstream tag: $LATEST_TAG"
    echo "- target branch: $BRANCH_NAME"
    echo "- patch: $patch"
    echo "- stage: $stage"
    echo

    echo "## git status (worktree)"
    echo '```'
    git -C "$OPENCODE_DIR" status --porcelain=v1 || true
    echo '```'
    echo

    echo "## unmerged/conflicted files"
    echo '```'
    git -C "$OPENCODE_DIR" diff --name-only --diff-filter=U || true
    echo '```'
    echo

    echo "## apply stderr"
    echo '```'
    if [[ -f "$stderr_file" ]]; then
      cat "$stderr_file"
    else
      echo "(no stderr captured)"
    fi
    echo '```'
    echo

    echo "## conflict snippets"
    local files
    files="$(git -C "$OPENCODE_DIR" diff --name-only --diff-filter=U || true)"
    if [[ -z "$files" ]]; then
      echo "(no unmerged files reported by git)"
    else
      for f in $files; do
        echo
        echo "### $f"
        echo '```'
        print_conflict_snippets "$OPENCODE_DIR/$f" 6
        echo '```'
      done
    fi

    echo
    echo "## agent next steps (recipe)"
    echo
    echo "1) Open the worktree: \`cd $OPENCODE_DIR\`"
    echo "2) Resolve conflicts in the files listed above (remove conflict markers)."
    echo "3) Validate build: \`bun install && bun run --cwd packages/opencode build\`"
    echo "4) Regenerate the patch from the upstream tag (repeat per patch):"
    echo
    echo '```bash'
    echo "cd $OPENCODE_DIR"
    echo "git diff $LATEST_TAG -- <files-you-changed> > $REPO_DIR/patches/$(basename "$patch")"
    echo '```'
    echo
    echo "5) Re-run: \`cd $REPO_DIR && ./update-and-build.sh\`"
  } > "$report"

  echo
  echo "ERROR: Patch failed ($stage): $patch" >&2
  echo "Wrote failure report: $report" >&2
  echo "Worktree left as-is for manual resolution: $OPENCODE_DIR" >&2
  echo
}

cd "$REPO_DIR"

# =============================================================================
# Preconditions
# =============================================================================
if ! command -v bun >/dev/null 2>&1; then
  echo "ERROR: bun is required. Install bun first (https://bun.sh)" >&2
  exit 1
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "ERROR: Not inside a git repository: $REPO_DIR" >&2
  exit 1
fi

# =============================================================================
# Setup upstream remote
# =============================================================================
if ! git remote get-url upstream >/dev/null 2>&1; then
  echo "=== Adding upstream remote ==="
  git remote add upstream "$UPSTREAM_URL_DEFAULT"
fi

echo "=== Fetching latest from upstream ==="
git fetch upstream --tags

# Only consider release tags like v1.2.4 (ignore tags like vscode-v0.0.13)
LATEST_TAG="$(git tag -l 'v[0-9]*' --sort=-v:refname | head -1)"
if [[ -z "$LATEST_TAG" ]]; then
  echo "ERROR: No tags found. Make sure upstream is accessible." >&2
  exit 1
fi

BRANCH_NAME="custom-${LATEST_TAG}"
VERSION="${LATEST_TAG#v}"

echo "Latest tag: $LATEST_TAG"
echo "Target branch: $BRANCH_NAME"

# =============================================================================
# Ensure opencode worktree exists (or refresh it)
# =============================================================================
if [[ ! -d "$OPENCODE_DIR" ]]; then
  echo "=== Creating opencode worktree: $OPENCODE_DIR ==="
  git worktree add "$OPENCODE_DIR" -b "$BRANCH_NAME" "$LATEST_TAG"
else
  if ! git -C "$OPENCODE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo "ERROR: '$OPENCODE_DIR' exists but is not a git worktree." >&2
    echo "Move it aside and re-run." >&2
    exit 1
  fi

  echo "=== Refreshing opencode worktree ==="
  git -C "$OPENCODE_DIR" reset --hard
  git -C "$OPENCODE_DIR" clean -fdx
  git -C "$OPENCODE_DIR" checkout -B "$BRANCH_NAME" "$LATEST_TAG"
fi

# =============================================================================
# Apply patches in opencode worktree
# =============================================================================
apply_patch() {
  local patch="$1"
  local apply_stderr
  apply_stderr="$(mktemp)"

  if git -C "$OPENCODE_DIR" apply --check "$patch" >/dev/null 2>&1; then
    if ! git -C "$OPENCODE_DIR" apply "$patch" 2>"$apply_stderr"; then
      write_patch_failure_report "apply" "$patch" "$apply_stderr"
      exit 1
    fi
  else
    echo "Patch did not apply cleanly; trying 3-way: $(basename "$patch")"
    if ! git -C "$OPENCODE_DIR" apply --3way "$patch" 2>"$apply_stderr"; then
      write_patch_failure_report "apply --3way" "$patch" "$apply_stderr"
      exit 1
    fi
  fi

  rm -f "$apply_stderr"
}

if [[ -d "$PATCH_DIR" ]]; then
  shopt -s nullglob
  PATCHES=("$PATCH_DIR"/*.patch)
  shopt -u nullglob

  if (( ${#PATCHES[@]} > 0 )); then
    echo "=== Applying patches (${#PATCHES[@]}) ==="
    for p in "${PATCHES[@]}"; do
      echo "- $(basename "$p")"
      apply_patch "$p"
    done
  else
    echo "=== No patches found in $PATCH_DIR (skipping) ==="
  fi
else
  echo "=== Patch dir not found: $PATCH_DIR (skipping) ==="
fi

# =============================================================================
# Build in opencode worktree
# =============================================================================
resolve_bin_path() {
  local base_dir="$1"
  if [[ "$OSTYPE" == "darwin"* ]]; then
    if [[ "$(uname -m)" == "arm64" ]]; then
      echo "$base_dir/opencode-darwin-arm64/bin/opencode"
    else
      echo "$base_dir/opencode-darwin-x64/bin/opencode"
    fi
  else
    echo "$base_dir/opencode-linux-x64/bin/opencode"
  fi
}

echo "=== Installing dependencies (opencode worktree) ==="
(
  cd "$OPENCODE_DIR"
  bun install
)

echo "=== Building opencode (opencode worktree) ==="
(
  cd "$OPENCODE_DIR"
  bun run --cwd packages/opencode build
)

BIN_TARGET="$(resolve_bin_path "$OPENCODE_DIR/packages/opencode/dist")"
if [[ ! -f "$BIN_TARGET" ]]; then
  echo "ERROR: Built binary not found at: $BIN_TARGET" >&2
  exit 1
fi
chmod +x "$BIN_TARGET" || true

# =============================================================================
# Commit so the opencode worktree remains clean (prevents future checkout issues)
# =============================================================================
(
  cd "$OPENCODE_DIR"
  git add -A
  git -c user.name="opencode-custom" -c user.email="opencode-custom@local" \
    commit -m "feat: apply local patches on ${LATEST_TAG}" >/dev/null 2>&1 || true
)

# =============================================================================
# Symlink ~/.opencode/bin/opencode -> this repo's built binary
# =============================================================================
mkdir -p "$BIN_LINK_DIR"
ln -sf "$BIN_TARGET" "$BIN_LINK_PATH"

# =============================================================================
# Done
# =============================================================================
echo
echo "=========================================="
echo "  Build complete: v$VERSION (patched)"
echo "=========================================="
echo

echo "Binary (in repo):"
echo "  $BIN_TARGET"
echo "Symlink:"
echo "  $BIN_LINK_PATH -> $BIN_TARGET"
echo
"$BIN_LINK_PATH" --version || true
