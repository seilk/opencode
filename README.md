# OpenCode Custom Build

Fork of [anomalyco/opencode](https://github.com/anomalyco/opencode) with patches for LiteLLM proxy compatibility.

## Patch: Gemini Finish Reason Fix

**Problem**: When using Gemini models through LiteLLM proxy (e.g., Letsur Gateway), the agent loop terminates after the first response instead of continuing with tool calls.

**Cause**: LiteLLM returns `finish_reason: "stop"` instead of `"tool_calls"` in streaming mode. ([LiteLLM #12240](https://github.com/BerriAI/litellm/issues/12240))

**Fix**: Detect tool calls by checking message parts, regardless of `finish_reason`.

## Usage

```bash
git clone git@github.com:seilk/opencode.git
cd opencode
./update-and-build.sh
```

This will:
1. Fetch the latest tag from upstream
2. Create a patched branch `fix-gemini-finish-reason-vX.X.X`
3. Apply the patch
4. Build and install to `~/.opencode/bin/`

Add to PATH:
```bash
export PATH="$HOME/.opencode/bin:$PATH"
```

## Files

- `update-and-build.sh` - Build script
- `patches/fix-gemini-finish-reason.patch` - The patch file

## Branch Structure

- `main` - Scripts and patches only (this branch)
- `fix-gemini-finish-reason-vX.X.X` - Patched builds based on upstream tags

## Upstream

https://github.com/anomalyco/opencode
