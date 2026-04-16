#!/usr/bin/env bash
# Shared helpers for the workflow automation.
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
  tmp="$(mktemp "${file}.XXXXXX")"
  if [[ -f "$file" ]]; then
    grep -v "^${key}=" "$file" > "$tmp" || true
  fi
  echo "${key}=${value}" >> "$tmp"
  mv "$tmp" "$file"
}

get_state_kv() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  # Guard each pipeline stage under `set -eo pipefail` in callers.
  { grep "^${key}=" "$file" 2>/dev/null || true; } | { tail -1 || true; } | { cut -d= -f2- || true; }
}

has_skip_label() {
  local labels_json="$1"
  shift
  for skip in "$@"; do
    if echo "$labels_json" | jq -e --arg s "$skip" 'any(.[]; .name == $s)' >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

is_numeric() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

branch_for_issue() { echo "${AUTO_BRANCH_PREFIX}$1"; }

# Claude CLI's bypassPermissions ignores whole-tool denials like Write/Edit,
# so even with those listed in --disallowedTools Claude can still touch any
# path in the repo. We enforce the "don't touch infra files" rule by scanning
# the commit range Claude produced and aborting if it strayed outside code.
# Echoes each forbidden path; returns 1 if any are found.
forbidden_paths_in_range() {
  local before="$1" after="$2"
  [[ "$before" == "$after" ]] && return 0
  local changed forbidden
  changed="$(git diff --name-only "$before" "$after")" || return 2
  forbidden="$(printf '%s\n' "$changed" \
    | grep -E '^(\.automation/|\.github/|\.git/hooks/|\.claude/)' || true)"
  if [[ -n "$forbidden" ]]; then
    printf '%s\n' "$forbidden"
    return 1
  fi
  return 0
}

# Denylist applied to every Claude invocation that runs Bash. Whole-tool
# entries (WebFetch, WebSearch) and sub-pattern entries (Bash(x:*)) are both
# enforced when --permission-mode is NOT bypassPermissions. Under
# bypassPermissions only the sub-pattern entries are reliably enforced, so
# everything dangerous is expressed as a Bash(...) pattern.
CLAUDE_DENYLIST="WebFetch,WebSearch"
CLAUDE_DENYLIST="$CLAUDE_DENYLIST,Bash(git push:*),Bash(git remote:*),Bash(git config:*),Bash(git fetch:*)"
CLAUDE_DENYLIST="$CLAUDE_DENYLIST,Bash(gh:*),Bash(curl:*),Bash(wget:*),Bash(ssh:*),Bash(scp:*),Bash(rsync:*),Bash(nc:*)"
CLAUDE_DENYLIST="$CLAUDE_DENYLIST,Bash(python:*),Bash(python3:*),Bash(node:*),Bash(perl:*),Bash(ruby:*)"
CLAUDE_DENYLIST="$CLAUDE_DENYLIST,Bash(socat:*),Bash(openssl:*),Bash(ftp:*),Bash(bash -c:*),Bash(sh -c:*)"
export CLAUDE_DENYLIST

# Download image attachments referenced in an issue/PR body.
# Echoes one local path per line. Restricted to trusted GitHub hosts,
# capped at 5 files and 10 MB each.
download_attachments() {
  local body="$1" issue="$2"
  local dest="$STATE_DIR/attachments/issue-$issue"
  mkdir -p "$dest"
  rm -f "$dest"/* 2>/dev/null || true

  # Reject any URL that carries userinfo (user:pass@host) or whitespace.
  # Host must be an exact GitHub-controlled domain; we anchor with a trailing
  # '/' or ':' in the regex so we don't match evil-github.com.
  local host_re='^https://(github\.com|user-images\.githubusercontent\.com|github-production-user-asset-[A-Za-z0-9-]+\.s3\.amazonaws\.com)(/|$)'

  local urls
  urls="$(printf '%s\n' "$body" \
    | grep -oE 'https://[A-Za-z0-9._/~%?=&#+:-]+' \
    | grep -v '@' \
    | grep -iE '\.(png|jpe?g|gif|webp)(\?|$)|/user-attachments/assets/|user-images\.githubusercontent' \
    | grep -E "$host_re" \
    | sort -u \
    | head -5 || true)"

  [[ -z "$urls" ]] && return 0

  local i=0
  while IFS= read -r url; do
    [[ -z "$url" ]] && continue
    i=$((i+1))
    local ext
    ext="$(echo "$url" | grep -oiE '\.(png|jpe?g|gif|webp)(\?|$)' | head -1 | tr -d '.?' | tr '[:upper:]' '[:lower:]')"
    [[ -z "$ext" ]] && ext="png"
    local path="$dest/attachment-$i.$ext"
    # Allow one redirect because github.com/.../assets/... 302s to s3, but no
    # more — keeps the final URL inside the trusted host set.
    if wget -q --timeout=20 --tries=2 --max-redirect=1 -O "$path" "$url" 2>/dev/null; then
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
