#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "=== Fetching latest from upstream ==="
git fetch upstream --tags

LATEST_TAG=$(git tag -l 'v1.*' | sort -V | tail -1)
echo "Latest tag: $LATEST_TAG"

BRANCH_NAME="fix-gemini-finish-reason-${LATEST_TAG}"
echo "=== Creating branch: $BRANCH_NAME ==="

git stash 2>/dev/null || true
git checkout -B "$BRANCH_NAME" "$LATEST_TAG"

echo "=== Applying patch ==="
if git apply --check patches/fix-gemini-finish-reason.patch 2>/dev/null; then
    git apply patches/fix-gemini-finish-reason.patch
else
    echo "Trying 3-way merge..."
    git apply --3way patches/fix-gemini-finish-reason.patch || {
        echo "ERROR: Patch failed. Manual intervention required."
        exit 1
    }
fi

CURRENT_BUN=$(bun --version)
sed -i "s/\"packageManager\": \"bun@[^\"]*\"/\"packageManager\": \"bun@$CURRENT_BUN\"/" package.json

echo "=== Building ==="
bun install
cd packages/opencode
rm -rf dist
bun run build

echo "=== Installing ==="
BINARY_NAME="opencode-fix-gemini-${LATEST_TAG}"
mkdir -p ~/.opencode/bin
cp dist/opencode-linux-x64/bin/opencode ~/.opencode/bin/"$BINARY_NAME"
ln -sf "$BINARY_NAME" ~/.opencode/bin/opencode

echo ""
echo "=== Done ==="
echo "Binary: ~/.opencode/bin/$BINARY_NAME"
~/.opencode/bin/opencode --version
