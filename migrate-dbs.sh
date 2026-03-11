#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${HOME}/.local/share/opencode"
TARGET=""
DRY_RUN=0
FORCE=0
declare -a SOURCES=()

TABLES=(
  "project"
  "workspace"
  "session"
  "message"
  "part"
  "todo"
  "permission"
  "session_share"
)

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Merge legacy opencode-*.db files into the canonical opencode.db offline.

Options:
  --data-dir DIR   Override the data directory (default: ~/.local/share/opencode)
  --target PATH    Override the canonical target DB path
  --source PATH    Merge a specific source DB (repeatable)
  --dry-run        Print the plan without modifying anything
  --force          Skip open-file safety checks
  --help           Show this help message

Examples:
  $(basename "$0")
  $(basename "$0") --dry-run
  $(basename "$0") --source "$HOME/.local/share/opencode/opencode-custom-v1.2.24.db"
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

sqlq() {
  local value="$1"
  value=${value//\'/\'\'}
  printf "'%s'" "$value"
}

db_files() {
  local db="$1"
  printf '%s\n' "$db"
  [[ -f "${db}-wal" ]] && printf '%s\n' "${db}-wal"
  [[ -f "${db}-shm" ]] && printf '%s\n' "${db}-shm"
}

checkpoint() {
  local db="$1"
  [[ -f "$db" ]] || return
  sqlite3 "$db" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null
}

table_exists() {
  local db="$1"
  local name="$2"
  local hit
  hit="$(sqlite3 "$db" "SELECT 1 FROM sqlite_master WHERE type='table' AND name=$(sqlq "$name");")"
  [[ "$hit" == "1" ]]
}

count() {
  local db="$1"
  local name="$2"
  if ! table_exists "$db" "$name"; then
    printf '0\n'
    return
  fi
  sqlite3 "$db" "SELECT COUNT(*) FROM $name;"
}

check_db() {
  local db="$1"
  local label="$2"
  local quick
  local full
  local fk
  quick="$(sqlite3 "$db" "PRAGMA quick_check;")"
  [[ "$quick" == "ok" ]] || die "$label quick_check failed: $quick"
  full="$(sqlite3 "$db" "PRAGMA integrity_check;")"
  [[ "$full" == "ok" ]] || die "$label integrity_check failed: $full"
  fk="$(sqlite3 "$db" "PRAGMA foreign_key_check;")"
  [[ -z "$fk" ]] || die "$label foreign_key_check failed: $fk"
}

report_counts() {
  local db="$1"
  local label="$2"
  printf '%s\n' "$label"
  local table
  for table in "${TABLES[@]}"; do
    printf '  %s: %s\n' "$table" "$(count "$db" "$table")"
  done
}

discover() {
  if (( ${#SOURCES[@]} > 0 )); then
    return
  fi

  shopt -s nullglob
  local glob=("$DATA_DIR"/opencode-*.db)
  shopt -u nullglob
  local file

  if (( ${#glob[@]} == 0 )); then
    return
  fi

  while IFS= read -r file; do
    SOURCES+=("$file")
  done < <(printf '%s\n' "${glob[@]}" | LC_ALL=C sort)
}

check_open() {
  (( FORCE == 1 )) && return

  local files=()
  local db
  for db in "$TARGET" "${SOURCES[@]}"; do
    while IFS= read -r file; do
      files+=("$file")
    done < <(db_files "$db")
  done

  (( ${#files[@]} == 0 )) && return

  local out
  out="$(lsof "${files[@]}" 2>/dev/null || true)"
  [[ -z "$out" ]] || die "Some opencode DB files are open. Stop opencode completely or rerun with --force if you know they are offline.\n$out"
}

copy_set() {
  local db="$1"
  local dst="$2"
  while IFS= read -r file; do
    cp -p "$file" "$dst/"
  done < <(db_files "$db")
}

merge() {
  local work="$1"
  local src="$2"
  local sql table

  sql="PRAGMA foreign_keys = ON; ATTACH DATABASE $(sqlq "$src") AS src; BEGIN IMMEDIATE;"
  for table in "${TABLES[@]}"; do
    if table_exists "$src" "$table"; then
      sql+="INSERT OR IGNORE INTO $table SELECT * FROM src.$table;"
    fi
  done
  sql+="COMMIT; DETACH DATABASE src;"

  sqlite3 -bail "$work" "$sql"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-dir)
      [[ -n "${2:-}" ]] || die "--data-dir requires a value"
      DATA_DIR="$2"
      shift 2
      ;;
    --target)
      [[ -n "${2:-}" ]] || die "--target requires a value"
      TARGET="$2"
      shift 2
      ;;
    --source)
      [[ -n "${2:-}" ]] || die "--source requires a value"
      SOURCES+=("$2")
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

need sqlite3
need lsof

TARGET="${TARGET:-$DATA_DIR/opencode.db}"
[[ -d "$DATA_DIR" ]] || die "Data directory not found: $DATA_DIR"
[[ -f "$TARGET" ]] || die "Target DB not found: $TARGET"

discover

if (( ${#SOURCES[@]} == 0 )); then
  printf 'No legacy source DBs found in %s\n' "$DATA_DIR"
  exit 0
fi

local_target="$(cd "$(dirname "$TARGET")" && pwd)/$(basename "$TARGET")"
TARGET="$local_target"

declare -a resolved=()
for src in "${SOURCES[@]}"; do
  [[ -f "$src" ]] || die "Source DB not found: $src"
  src="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"
  [[ "$src" != "$TARGET" ]] || die "Source DB must not be the target DB: $src"
  resolved+=("$src")
done
SOURCES=("${resolved[@]}")

check_open

for db in "$TARGET" "${SOURCES[@]}"; do
  checkpoint "$db"
done

check_db "$TARGET" "target"
for src in "${SOURCES[@]}"; do
  check_db "$src" "source $src"
done

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$(mktemp -d "$DATA_DIR/db-merge-backup-$STAMP.XXXXXX")"
WORK_DIR="$(mktemp -d "$DATA_DIR/db-merge-work-$STAMP.XXXXXX")"
WORK_DB="$WORK_DIR/opencode.db"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

printf '=== opencode offline DB merge ===\n'
printf 'Repo: %s\n' "$REPO_DIR"
printf 'Data dir: %s\n' "$DATA_DIR"
printf 'Target: %s\n' "$TARGET"
printf 'Backup: %s\n' "$BACKUP_DIR"
printf 'Sources (%s):\n' "${#SOURCES[@]}"
for src in "${SOURCES[@]}"; do
  printf '  - %s\n' "$src"
done

if (( DRY_RUN == 1 )); then
  printf 'Dry run only. No files were modified.\n'
  exit 0
fi

copy_set "$TARGET" "$BACKUP_DIR"
for src in "${SOURCES[@]}"; do
  copy_set "$src" "$BACKUP_DIR"
done

cp -p "$TARGET" "$WORK_DB"

report_counts "$WORK_DB" "--- Pre-merge counts ---"

for src in "${SOURCES[@]}"; do
  printf -- '--- Merging: %s ---\n' "$src"
  merge "$WORK_DB" "$src"
  check_db "$WORK_DB" "work DB after merging $src"
done

report_counts "$WORK_DB" "--- Post-merge counts ---"

rm -f "${TARGET}-wal" "${TARGET}-shm"
mv "$WORK_DB" "$TARGET"
sqlite3 "$TARGET" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null || true

printf '=== Merge complete ===\n'
printf 'Canonical DB: %s\n' "$TARGET"
printf 'Backup dir: %s\n' "$BACKUP_DIR"
printf 'Verify: sqlite3 %q "PRAGMA integrity_check;"\n' "$TARGET"
printf 'Verify: sqlite3 %q "PRAGMA foreign_key_check;"\n' "$TARGET"
