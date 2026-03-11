#!/usr/bin/env bash
set -euo pipefail

# update-and-build.sh
#
# Thin wrapper: shallow-clone upstream OpenCode by tag, apply local patches,
# build the binary, and symlink it to ~/.opencode/bin/opencode.
#
# Usage:
#   ./update-and-build.sh              # update to latest upstream tag
#   ./update-and-build.sh --reset      # nuke all local state, rebuild fresh
#   ./update-and-build.sh --tag v1.2.0 # build a specific version
#   ./update-and-build.sh --help

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAM_URL="https://github.com/anomalyco/opencode.git"
PATCH_DIR="$REPO_DIR/patches"
LOG_DIR="$REPO_DIR/logs"
STATE_DIR="$REPO_DIR/state"
RUN_ID="$(date +%Y%m%d-%H%M%S)"

BUILD_DIR="$REPO_DIR/opencode"

BIN_LINK_DIR="$HOME/.opencode/bin"
BIN_LINK_PATH="$BIN_LINK_DIR/opencode"

# Parsed from CLI args
FLAG_RESET=0
FLAG_TAG=""

# =============================================================================
# CLI argument parsing
# =============================================================================
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Update OpenCode from upstream, apply local patches, build, and symlink binary.

Options:
  --reset       Remove all local build state and rebuild from scratch
  --tag TAG     Build a specific upstream tag (e.g. v1.2.0) instead of latest
  --help        Show this help message

Examples:
  $(basename "$0")                # update to latest
  $(basename "$0") --reset        # clean slate rebuild
  $(basename "$0") --tag v1.2.0   # pin to specific version
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset)  FLAG_RESET=1; shift ;;
    --tag)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --tag requires a value (e.g. --tag v1.2.0)" >&2
        exit 1
      fi
      FLAG_TAG="$2"; shift 2 ;;
    --help|-h) usage ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      echo "Run with --help for usage." >&2
      exit 1 ;;
  esac
done

# =============================================================================
# Helpers
# =============================================================================
die() { echo "ERROR: $*" >&2; exit 1; }

mkdir -p "$LOG_DIR" "$STATE_DIR"

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

write_patch_failure_report() {
  local stage="$1"
  local patch="$2"
  local stderr_file="$3"

  local report="$LOG_DIR/patch-failure_${TARGET_TAG}_${RUN_ID}_$(basename "$patch" .patch).md"

  {
    echo "# Patch failure report (opencode-custom)"
    echo
    echo "- time: $(date)"
    echo "- repo: $REPO_DIR"
    echo "- build dir: $BUILD_DIR"
    echo "- upstream tag: $TARGET_TAG"
    echo "- patch: $patch"
    echo "- stage: $stage"
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

    echo "## git status"
    echo '```'
    git -C "$BUILD_DIR" status --porcelain=v1 2>/dev/null || true
    echo '```'
    echo

    echo "## agent next steps"
    echo
    echo "1) Inspect the build dir: \`cd $BUILD_DIR\`"
    echo "2) Resolve conflicts, then validate: \`bun install && bun run --cwd packages/opencode build\`"
    echo "3) Regenerate the patch:"
    echo '```bash'
    echo "cd $BUILD_DIR"
    echo "git diff HEAD -- <files-you-changed> > $REPO_DIR/patches/$(basename "$patch")"
    echo '```'
    echo "4) Re-run: \`cd $REPO_DIR && ./update-and-build.sh\`"
  } > "$report"

  echo
  echo "ERROR: Patch failed ($stage): $(basename "$patch")" >&2
  echo "Report: $report" >&2
  echo "Build dir left for inspection: $BUILD_DIR" >&2
  echo
}

get_active_tag() {
  if [[ -f "$STATE_DIR/current-tag" ]]; then
    cat "$STATE_DIR/current-tag"
    return
  fi
  echo ""
}

# =============================================================================
# Install bun if not available
# =============================================================================
if ! command -v bun >/dev/null 2>&1; then
  echo "=== Installing bun ==="
  curl -fsSL https://bun.sh/install | bash \
    || die "Failed to install bun (network error?)"
  export BUN_INSTALL="$HOME/.bun"
  export PATH="$BUN_INSTALL/bin:$PATH"
  command -v bun >/dev/null 2>&1 || die "bun not found after installation"
  echo "Bun installed: $(bun --version)"
fi

# =============================================================================
# Handle --reset
# =============================================================================
if (( FLAG_RESET == 1 )); then
  echo "=== Resetting all local build state ==="
  rm -rf "$BUILD_DIR"
  rm -f "$STATE_DIR/current-tag"
  echo "Cleared: opencode/, state"
fi

# =============================================================================
# Resolve target tag
# =============================================================================
if [[ -n "$FLAG_TAG" ]]; then
  TARGET_TAG="$FLAG_TAG"
  echo "Target tag (pinned): $TARGET_TAG"
else
  echo "=== Querying latest upstream tag ==="
  local_tags="$(git ls-remote --tags --sort=-v:refname "$UPSTREAM_URL" 'v[0-9]*' 2>&1)" \
    || die "Failed to query upstream tags at $UPSTREAM_URL (network error?)"
  TARGET_TAG="$(echo "$local_tags" | grep -v '\^{}$' | head -1 | sed 's|.*refs/tags/||')"

  if [[ -z "$TARGET_TAG" ]]; then
    die "No tags found at $UPSTREAM_URL"
  fi
  echo "Latest tag: $TARGET_TAG"
fi

VERSION="${TARGET_TAG#v}"

# =============================================================================
# Skip if already up to date (unless --reset was used)
# =============================================================================
ACTIVE_TAG="$(get_active_tag)"

if (( FLAG_RESET == 0 )) && [[ -n "$ACTIVE_TAG" && "$ACTIVE_TAG" == "$TARGET_TAG" && -d "$BUILD_DIR" ]]; then
  echo "Already up to date: $TARGET_TAG"
  echo "Binary: $BIN_LINK_PATH"
  exit 0
fi

# =============================================================================
# Shallow clone upstream into build dir
# =============================================================================
rm -rf "$BUILD_DIR"

echo "=== Cloning $TARGET_TAG (shallow) ==="
git clone --depth 1 --branch "$TARGET_TAG" "$UPSTREAM_URL" "$BUILD_DIR" 2>&1 \
  || die "Failed to clone $TARGET_TAG from $UPSTREAM_URL"

# =============================================================================
# Apply patches (sorted glob)
# =============================================================================
if [[ -d "$PATCH_DIR" ]]; then
  shopt -s nullglob
  PATCHES=("$PATCH_DIR"/*.patch)
  shopt -u nullglob

  if (( ${#PATCHES[@]} > 0 )); then
    echo "=== Applying patches (${#PATCHES[@]}) ==="
    for p in "${PATCHES[@]}"; do
      echo "- $(basename "$p")"
      apply_stderr="$(mktemp)"
      if ! git -C "$BUILD_DIR" apply "$p" 2>"$apply_stderr"; then
        write_patch_failure_report "apply" "$p" "$apply_stderr"
        rm -f "$apply_stderr"
        exit 1
      fi
      rm -f "$apply_stderr"
    done
  else
    echo "=== No patches found (skipping) ==="
  fi
fi

# =============================================================================
# Build
# =============================================================================
echo "=== Installing dependencies ==="
(cd "$BUILD_DIR" && bun install) \
  || die "bun install failed in $BUILD_DIR"

echo "=== Building ==="
(cd "$BUILD_DIR" && bun run --cwd packages/opencode build) \
  || die "bun run build failed in $BUILD_DIR"

# =============================================================================
# Verify binary exists
# =============================================================================
BIN_TARGET="$(resolve_bin_path "$BUILD_DIR/packages/opencode/dist")"
if [[ ! -f "$BIN_TARGET" ]]; then
  echo "ERROR: Built binary not found at: $BIN_TARGET" >&2
  exit 1
fi
chmod +x "$BIN_TARGET" || true

# =============================================================================
# Symlink binary
# =============================================================================
mkdir -p "$BIN_LINK_DIR"
ln -sf "$BIN_TARGET" "$BIN_LINK_PATH"
echo "$TARGET_TAG" > "$STATE_DIR/current-tag"

echo
echo "=========================================="
echo "  Build complete: v$VERSION (patched)"
echo "=========================================="
echo
echo "Binary: $BIN_TARGET"
echo "Symlink: $BIN_LINK_PATH -> $BIN_TARGET"
echo
"$BIN_LINK_PATH" --version || true
