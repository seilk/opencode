# OpenCode Custom Patch Guide

This document explains how to manage custom patched versions of OpenCode.

## Repository Structure

```
~/opencode-custom/
├── AGENTS.md                              # This document
├── README.md                              # Usage summary
├── .gitignore
├── patches/
│   └── fix-gemini-finish-reason.patch     # Patch files
└── update-and-build.sh                    # Build script
```

### Branch Structure

| Branch | Purpose |
|--------|---------|
| `main` | Scripts and patch files only (no upstream code) |
| `fix-gemini-finish-reason-vX.X.X` | Patched branch based on specific version |

### Remote Structure

| Remote | URL | Purpose |
|--------|-----|---------|
| `origin` | `git@github.com:seilk/opencode.git` | My fork |
| `upstream` | `https://github.com/anomalyco/opencode.git` | Original repository |

---

## Current Patches

### 1. fix-gemini-finish-reason.patch

**Problem**: When using Gemini models through LiteLLM proxy (e.g., Letsur Gateway), the agent loop terminates after the first response instead of continuing with tool calls in streaming mode.

**Cause**: LiteLLM bug - returns `finish_reason: "stop"` instead of `"tool_calls"` in streaming mode ([GitHub Issue #12240](https://github.com/BerriAI/litellm/issues/12240))

**Modified File**: `packages/opencode/src/session/prompt.ts`

**Fix**: Check for tool call existence in message parts regardless of `finish_reason` value.

---

## Adding a New Patch

### Step 1: Identify Files to Modify

First, identify which files need modification in the upstream code.

```bash
cd ~/opencode-custom

# Create temporary branch from latest upstream tag
git fetch upstream --tags
LATEST=$(git tag -l 'v1.*' | sort -V | tail -1)
git checkout -b temp-patch $LATEST
```

### Step 2: Modify Code

Edit the necessary files.

```bash
# Example: modify prompt.ts
vim packages/opencode/src/session/prompt.ts
```

### Step 3: Generate Patch File

Extract your modifications as a patch file.

```bash
# Extract specific file as patch
git diff HEAD -- packages/opencode/src/session/prompt.ts > /tmp/my-new-fix.patch

# Or extract all changes
git diff HEAD > /tmp/my-new-fix.patch
```

### Step 4: Add Patch File to main Branch

```bash
git checkout main
cp /tmp/my-new-fix.patch patches/my-new-fix.patch
git add patches/my-new-fix.patch
git commit -m "Add patch: my-new-fix"
git push origin main
```

### Step 5: Update update-and-build.sh

Modify the build script to apply the new patch.

```bash
# Add below existing patch application line
git apply patches/my-new-fix.patch
```

### Step 6: Delete Temporary Branch

```bash
git branch -D temp-patch
```

---

## Modifying Existing Patches

When you need to update an existing patch:

### Step 1: Work on Patched Branch

```bash
cd ~/opencode-custom
git checkout fix-gemini-finish-reason-v1.1.31  # Current patched branch
```

### Step 2: Modify Code

```bash
vim packages/opencode/src/session/prompt.ts
```

### Step 3: Generate New Patch File

```bash
# Generate patch by comparing with upstream tag
git diff v1.1.31 -- packages/opencode/src/session/prompt.ts > /tmp/updated-patch.patch
```

### Step 4: Update main Branch

```bash
git checkout main
cp /tmp/updated-patch.patch patches/fix-gemini-finish-reason.patch
git add patches/fix-gemini-finish-reason.patch
git commit -m "Update patch: fix-gemini-finish-reason"
git push origin main
```

---

## Following Upstream Updates

When a new version is released:

```bash
cd ~/opencode-custom
./update-and-build.sh
```

The script automatically:
1. Add `upstream` remote if not exists (points to official OpenCode repo)
2. `git fetch upstream --tags` - Fetch latest tags
3. Backup patch files to `~/tmp/` (survives branch switch)
4. Create new branch based on latest tag
5. Apply patches from `~/tmp/`
6. Build and install

### Resolving Patch Conflicts

If the patch fails to apply (upstream code changed significantly):

```bash
# If script fails, proceed manually
# First, backup patch to ~/tmp/ (script does this automatically)
cp patches/fix-gemini-finish-reason.patch ~/tmp/

# Checkout the new version
git checkout -b fix-gemini-finish-reason-vX.X.X vX.X.X

# Try patch with 3-way merge
git apply --3way ~/tmp/fix-gemini-finish-reason.patch

# If conflict occurs, resolve manually
vim packages/opencode/src/session/prompt.ts
# ... make fixes ...

git add .
git commit -m "fix: Gemini/LiteLLM finish_reason workaround"

# Update patch file in main branch
git diff vX.X.X -- packages/opencode/src/session/prompt.ts > ~/tmp/fix-gemini-finish-reason.patch
git checkout main
cp ~/tmp/fix-gemini-finish-reason.patch patches/fix-gemini-finish-reason.patch
git add patches/fix-gemini-finish-reason.patch
git commit -m "Update patch for vX.X.X"
git push origin main
```

---

## Build Output

After build completion, binary location:

```
~/.opencode/bin/
├── opencode -> opencode-fix-gemini-vX.X.X  (symlink)
└── opencode-fix-gemini-vX.X.X              (actual binary)
```

Add to PATH:
```bash
export PATH="$HOME/.opencode/bin:$PATH"
```

---

## Troubleshooting

### Patch Fails to Apply

```bash
# Validate patch
git apply --check patches/fix-gemini-finish-reason.patch

# Check which parts conflict
git apply --verbose patches/fix-gemini-finish-reason.patch
```

### Build Fails

```bash
# Check bun version
bun --version

# Reinstall node_modules
rm -rf node_modules
bun install

# Rebuild
cd packages/opencode && bun run build
```

### Missing upstream Remote

The script automatically adds upstream remote if missing. If you need to do it manually:

```bash
git remote add upstream https://github.com/anomalyco/opencode.git
git fetch upstream --tags
```

---

## Complete Workflow Example

Here's a complete example of adding a new feature patch:

```bash
# 1. Setup
cd ~/opencode-custom
git fetch upstream --tags
LATEST=$(git tag -l 'v1.*' | sort -V | tail -1)
echo "Latest version: $LATEST"

# 2. Create working branch
git checkout -b temp-my-feature $LATEST

# 3. Make your changes
vim packages/opencode/src/some/file.ts

# 4. Test your changes (optional but recommended)
cd packages/opencode
bun install
bun run build
# Test manually...

# 5. Generate patch
cd ~/opencode-custom
git diff $LATEST -- packages/opencode/src/ > /tmp/my-feature.patch

# 6. Add to main branch
git checkout main
cp /tmp/my-feature.patch patches/my-feature.patch

# 7. Update build script if needed
vim update-and-build.sh
# Add: git apply patches/my-feature.patch

# 8. Commit and push
git add .
git commit -m "Add patch: my-feature"
git push origin main

# 9. Cleanup
git branch -D temp-my-feature

# 10. Test full build
./update-and-build.sh
```

---

## References

- **Upstream**: https://github.com/anomalyco/opencode
- **LiteLLM Issue**: https://github.com/BerriAI/litellm/issues/12240
- **OpenCode Docs**: https://opencode.ai/docs
