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

BIN_LINK_DIR="$HOME/.opencode/bin"
BIN_LINK_PATH="$BIN_LINK_DIR/opencode"

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
  if git -C "$OPENCODE_DIR" apply --check "$patch" >/dev/null 2>&1; then
    git -C "$OPENCODE_DIR" apply "$patch"
  else
    echo "Patch did not apply cleanly; trying 3-way: $(basename "$patch")"
    git -C "$OPENCODE_DIR" apply --3way "$patch" || {
      echo "ERROR: Patch failed: $patch" >&2
      exit 1
    }
  fi
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
