#!/usr/bin/env bash
# Shared helpers for the autoreason automation.
set -euo pipefail

AUTO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$AUTO_ROOT/.." && pwd)"
STATE_DIR="$AUTO_ROOT/state"
LOG_DIR="$AUTO_ROOT/logs"
DRAFTS_DIR="$AUTO_ROOT/drafts"
PROMPTS_DIR="$AUTO_ROOT/prompts"
PAUSE_FILE="$AUTO_ROOT/PAUSE"
LOCK_FILE="$AUTO_ROOT/state/.lock"

SKIP_ISSUE_LABELS=("no-auto" "blocked" "wontfix" "duplicate" "question")
SKIP_PR_LABELS=("no-auto")
AUTO_BRANCH_PREFIX="auto/issue-"

mkdir -p "$STATE_DIR" "$LOG_DIR" "$DRAFTS_DIR"

log() {
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] $*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

paused() {
  [[ -f "$PAUSE_FILE" ]]
}

acquire_lock() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another cycle is already running"
}

state_file_for_issue() { echo "$STATE_DIR/issue-$1.state"; }
state_file_for_pr()    { echo "$STATE_DIR/pr-$1.state"; }

read_state() {
  local file="$1"
  if [[ -f "$file" ]]; then cat "$file"; fi
}

write_state_kv() {
  local file="$1" key="$2" value="$3"
  local tmp
  tmp="$(mktemp)"
  if [[ -f "$file" ]]; then
    grep -v "^${key}=" "$file" > "$tmp" || true
  fi
  echo "${key}=${value}" >> "$tmp"
  mv "$tmp" "$file"
}

get_state_kv() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  grep "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

has_skip_label() {
  local labels_json="$1"
  shift
  local skip_list=("$@")
  for skip in "${skip_list[@]}"; do
    if echo "$labels_json" | grep -q "\"$skip\""; then
      return 0
    fi
  done
  return 1
}

branch_for_issue() { echo "${AUTO_BRANCH_PREFIX}$1"; }

# Download image attachments referenced in an issue/PR body.
# Echoes one local path per line. Caps each file at 10 MB.
download_attachments() {
  local body="$1" issue="$2"
  local dest="$STATE_DIR/attachments/issue-$issue"
  mkdir -p "$dest"
  rm -f "$dest"/* 2>/dev/null || true

  local urls
  urls="$(printf '%s\n' "$body" \
    | grep -oE 'https?://[A-Za-z0-9._/~%?=&#+:@-]+' \
    | grep -iE '\.(png|jpe?g|gif|webp)(\?|$)|user-attachments/assets|user-images\.githubusercontent' \
    | sort -u || true)"

  [[ -z "$urls" ]] && return 0

  local i=0
  while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    i=$((i+1))
    local ext
    ext="$(echo "$url" | grep -oiE '\.(png|jpe?g|gif|webp)(\?|$)' | head -1 | tr -d '.?' | tr '[:upper:]' '[:lower:]')"
    [[ -z "$ext" ]] && ext="png"
    local path="$dest/attachment-$i.$ext"
    if wget -q --timeout=20 --tries=2 --max-redirect=5 -O "$path" "$url" 2>/dev/null; then
      local size
      size=$(stat -c%s "$path" 2>/dev/null || echo 0)
      if [[ "$size" -gt 0 && "$size" -lt 10485760 ]]; then
        echo "$path"
      else
        rm -f "$path"
      fi
    else
      rm -f "$path"
    fi
  done <<< "$urls"
}
