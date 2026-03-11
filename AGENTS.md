# opencode-custom

Thin wrapper repo: local patches on upstream [OpenCode](https://github.com/anomalyco/opencode).

```
~/opencode-custom/
├── patches/*.patch        # local patches (tracked)
├── update-and-build.sh    # build script (tracked)
├── state/current-tag      # active version (gitignored)
├── opencode/              # shallow clone + build (gitignored)
└── logs/                  # failure reports (gitignored)
```

---

## Quick Start

```bash
cd ~/opencode-custom
./update-and-build.sh              # update to latest upstream tag
./update-and-build.sh --reset      # nuke all local state, rebuild from scratch
./update-and-build.sh --tag v1.2.0 # build a specific version
```

On a fresh machine:
```bash
git clone <this-repo> ~/opencode-custom
cd ~/opencode-custom
./update-and-build.sh
# If bun is missing, the script installs it automatically.
# Binary is symlinked to ~/.opencode/bin/opencode
```

---

## How It Works

1. Queries latest upstream tag via `git ls-remote` (no local upstream remote needed).
2. Shallow-clones the target tag into `opencode/`.
3. Applies all `patches/*.patch` in sorted order via `git apply`.
4. Runs `bun install && bun run --cwd packages/opencode build`.
5. Verifies the built binary exists and symlinks `~/.opencode/bin/opencode` to it.
6. On failure: build dir left for inspection, previous binary untouched.

The build dir is a fully independent shallow clone. No shared git state, no branch management.

---

## Outputs / Paths

- Built binary (macOS arm64): `~/opencode-custom/opencode/packages/opencode/dist/opencode-darwin-arm64/bin/opencode`
- System symlink: `~/.opencode/bin/opencode` → built binary

---

## Local Patches

Current:
- `patches/fix-claude-thinking-blocks.patch`
- `patches/fix-gemini-finish-reason.patch`

Patches are applied in alphabetical order. Prefix with `NNN-` for deterministic ordering.

---

## Failure Behavior

If a patch fails to apply:
- Script stops immediately.
- A failure report is written to `logs/patch-failure_<tag>_<timestamp>_<patchname>.md`.
- The build dir is left as-is for manual inspection.

---

## Agent Repair Recipe

1. Inspect the build dir:
```bash
cd ~/opencode-custom/opencode
git status
```

2. Fix the patch conflicts, then validate:
```bash
bun install && bun run --cwd packages/opencode build
```

3. Regenerate the patch:
```bash
git diff HEAD -- <files-you-changed> > ~/opencode-custom/patches/<patch-name>.patch
```

4. Re-run:
```bash
cd ~/opencode-custom
./update-and-build.sh --reset
```

---

## Repo Rules

- Wrapper `main` contains only patches, script, and docs.
- All local modifications are expressed as `patches/*.patch`.
- Build dir (`opencode/`) is a disposable shallow clone.
- Never vendor upstream source into this repo.
