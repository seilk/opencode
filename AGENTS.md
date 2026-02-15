# opencode-custom — Wrapper Repo for Upstream OpenCode + Local Patches

This repo is intentionally **thin**.

- `main` stores only:
  - patch files (`patches/*.patch`)
  - one build script (`update-and-build.sh`)
  - docs
- Upstream OpenCode source code lives in a **separate git worktree** at:
  - `~/opencode-custom/opencode/`

Goal: reliably track the latest upstream release, apply local patches, build a working `opencode` binary inside this repo, and keep branch switching clean.

---

## Quick Start (the only command you usually need)

```bash
cd ~/opencode-custom
./update-and-build.sh
```

What it does:
1) Fetches upstream tags.
2) Picks latest **release tag** like `v1.2.4` (ignores non-release tags like `vscode-v*`).
3) Refreshes the worktree (`opencode/`) to a deterministic state:
   - `reset --hard` + `clean -fdx`
   - `checkout -B custom-<tag> <tag>`
4) Applies every patch in `patches/*.patch`.
5) Builds OpenCode.
6) Commits the patched result inside the worktree branch so the worktree stays clean.
7) Updates symlink:
   - `/Users/seil/.opencode/bin/opencode` → the binary built inside this repo

---

## Outputs / Paths

### Worktree
- Upstream checkout (patched) lives at:
  - `~/opencode-custom/opencode/`

### Built binary
- Built binary is created inside the worktree, e.g. on macOS arm64:
  - `~/opencode-custom/opencode/packages/opencode/dist/opencode-darwin-arm64/bin/opencode`

### System symlink
- The terminal `opencode` command is wired to the repo build via:
  - `/Users/seil/.opencode/bin/opencode` (symlink)

---

## Patch Failure Behavior (important)

If upstream changes and a patch cannot be applied:
- The script **stops immediately** (non-zero exit).
- The wrapper repo (`~/opencode-custom`, `main`) stays clean.
- The worktree (`~/opencode-custom/opencode/`) is left in the conflicted state for inspection.
- A **repair log** is written to:
  - `~/opencode-custom/logs/patch-failure_<tag>_<timestamp>_<patchname>.md`

The log contains:
- which patch failed and whether it was `apply` vs `apply --3way`
- `git status --porcelain`
- unmerged/conflicted file list
- conflict marker snippets (<<<<<<< / ======= / >>>>>>>)
- a short “agent next steps” recipe

---

## Agent Repair Recipe (how to update patches for a new upstream tag)

1) Open the worktree and see what’s conflicted:
```bash
cd ~/opencode-custom/opencode
git status
```

2) Resolve conflicts and remove conflict markers from files.

3) Validate build:
```bash
bun install
bun run --cwd packages/opencode build
```

4) Regenerate patch(es) against the upstream tag:
```bash
# From inside the worktree
cd ~/opencode-custom/opencode

# Example: regenerate one patch after fixing files
git diff <tag> -- <files-you-changed> > ~/opencode-custom/patches/<patch-name>.patch
```

5) Re-run the wrapper script to confirm clean apply/build:
```bash
cd ~/opencode-custom
./update-and-build.sh
```

6) Commit updates on wrapper `main` (patch + script/doc changes only).

---

## Repo Rules (so it never gets messy again)

- Do not vendor upstream source into wrapper `main`.
- Do not track `opencode/` (worktree) changes on wrapper `main`.
- All local modifications must be expressed as `patches/*.patch`.
- Logs go under `logs/` (ignored by git).
