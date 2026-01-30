#!/bin/bash
set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$HOME/tmp"

cd "$REPO_DIR"

mkdir -p "$TMP_DIR"

if ! git remote get-url upstream &>/dev/null; then
    echo "=== Adding upstream remote ==="
    git remote add upstream https://github.com/anomalyco/opencode.git
fi

echo "=== Fetching latest from upstream ==="
git fetch upstream --tags

LATEST_TAG=$(git tag -l 'v1.*' | sort -V | tail -1)
if [ -z "$LATEST_TAG" ]; then
    echo "ERROR: No tags found. Make sure upstream is accessible."
    exit 1
fi
echo "Latest tag: $LATEST_TAG"

CURRENT_VERSION=$(git branch -l 'fix-gemini-finish-reason-v*' | sort -V | tail -1 | sed 's/.*-\(v[0-9.]*\)/\1/')
if [ "$CURRENT_VERSION" = "$LATEST_TAG" ]; then
    echo "Already up to date: $LATEST_TAG"
    exit 0
fi

echo "=== Backing up patch ==="
cp "$REPO_DIR/patches/fix-gemini-finish-reason.patch" "$TMP_DIR/fix-gemini-finish-reason.patch"

BRANCH_NAME="fix-gemini-finish-reason-${LATEST_TAG}"
echo "=== Creating branch: $BRANCH_NAME ==="

git checkout -B "$BRANCH_NAME" "$LATEST_TAG"

echo "=== Applying patch ==="
if git apply --check "$TMP_DIR/fix-gemini-finish-reason.patch" 2>/dev/null; then
    git apply "$TMP_DIR/fix-gemini-finish-reason.patch"
else
    echo "Trying 3-way merge..."
    git apply --3way "$TMP_DIR/fix-gemini-finish-reason.patch" || {
        echo "ERROR: Patch failed. Manual intervention required."
        exit 1
    }
fi

CURRENT_BUN=$(bun --version)
# Cross-platform sed -i (macOS BSD vs GNU)
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i "" "s/\"packageManager\": \"bun@[^\"]*\"/\"packageManager\": \"bun@$CURRENT_BUN\"/" package.json
else
    sed -i "s/\"packageManager\": \"bun@[^\"]*\"/\"packageManager\": \"bun@$CURRENT_BUN\"/" package.json
fi

echo "=== Building ==="
bun install
cd packages/opencode
rm -rf dist
bun run build

echo "=== Installing ==="
BINARY_NAME="opencode-fix-gemini-${LATEST_TAG}"
mkdir -p ~/.opencode/bin

if [[ "$OSTYPE" == "darwin"* ]]; then
    if [[ "$(uname -m)" == "arm64" ]]; then
        BINARY_PATH="dist/opencode-darwin-arm64/bin/opencode"
    else
        BINARY_PATH="dist/opencode-darwin-x64/bin/opencode"
    fi
else
    BINARY_PATH="dist/opencode-linux-x64/bin/opencode"
fi

ORIGINAL_OPENCODE=$(command -v opencode 2>/dev/null || true)
if [ -n "$ORIGINAL_OPENCODE" ] && [ -f "$ORIGINAL_OPENCODE" ] && [ ! -L "$ORIGINAL_OPENCODE" ]; then
    if [ ! -f "${ORIGINAL_OPENCODE}.bak" ]; then
        echo "Backing up original opencode to ${ORIGINAL_OPENCODE}.bak"
        cp "$ORIGINAL_OPENCODE" "${ORIGINAL_OPENCODE}.bak"
    fi
fi

cp "$BINARY_PATH" ~/.opencode/bin/"$BINARY_NAME"
ln -sf "$BINARY_NAME" ~/.opencode/bin/opencode

echo "=== Committing changes ==="
git add -A
git commit -m "feat: apply custom patch on $LATEST_TAG"

echo "=== Configuring PATH ==="
PATH_LINE='export PATH="$HOME/.opencode/bin:$PATH"'
SHELL_NAME=$(basename "$SHELL")
case "$SHELL_NAME" in
    zsh)  RC_FILE="$HOME/.zshrc" ;;
    bash) RC_FILE="$HOME/.bashrc" ;;
    *)    RC_FILE="" ;;
esac

if [ -n "$RC_FILE" ]; then
    if ! grep -qF '.opencode/bin' "$RC_FILE" 2>/dev/null; then
        echo "" >> "$RC_FILE"
        echo "$PATH_LINE" >> "$RC_FILE"
        echo "Added PATH to $RC_FILE"
        echo "Run 'source $RC_FILE' or restart terminal to apply"
    else
        echo "PATH already configured in $RC_FILE"
    fi
else
    echo "Unknown shell: $SHELL_NAME. Add manually: $PATH_LINE"
fi

echo ""
echo "=== Done ==="
echo "Binary: ~/.opencode/bin/$BINARY_NAME"
~/.opencode/bin/opencode --version
