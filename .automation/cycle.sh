#!/usr/bin/env bash
# One iteration of the workflow loop. Called by systemd timer every 15 min.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOG_FILE="$LOG_DIR/cycle-$(date '+%Y%m%d').log"
exec >> "$LOG_FILE" 2>&1

find "$LOG_DIR" -name 'cycle-*.log' -mtime +30 -delete 2>/dev/null || true

log "========== cycle start =========="

if paused; then
  log "PAUSE file present; exiting"
  exit 0
fi

acquire_lock

cd "$REPO_ROOT"

# 1. Issues: classify new ones. Cap classifications per cycle to bound cost —
# 50 new issues * $0.50 budget each would be $25 per tick otherwise.
MAX_CLASSIFY_PER_CYCLE="${MAX_CLASSIFY_PER_CYCLE:-10}"
CLASSIFIED=0

log "step 1: listing open issues assigned to @me"
ISSUES_JSON="$(gh issue list --state open --assignee @me --limit 200 --json number,updatedAt,labels)"
while read -r row; do
  NUM="$(echo "$row" | jq -r '.number')"
  UPDATED="$(echo "$row" | jq -r '.updatedAt')"
  STATE_FILE="$(state_file_for_issue "$NUM")"
  CURRENT="$(get_state_kv "$STATE_FILE" status)"
  LAST_UPDATED="$(get_state_kv "$STATE_FILE" last_issue_updated)"

  do_classify=0
  case "$CURRENT" in
    ready|pr_opened)
      # handled by later steps
      ;;
    blocked|skipped|closed|failed|no_change)
      [[ "$UPDATED" != "$LAST_UPDATED" ]] && do_classify=1
      ;;
    needs_info)
      [[ "$UPDATED" != "$LAST_UPDATED" ]] && do_classify=1
      ;;
    *)
      do_classify=1
      ;;
  esac

  if [[ "$do_classify" -eq 1 ]]; then
    if [[ "$CLASSIFIED" -ge "$MAX_CLASSIFY_PER_CYCLE" ]]; then
      log "issue #$NUM: classify cap ($MAX_CLASSIFY_PER_CYCLE) reached, deferring"
      continue
    fi
    log "issue #$NUM: classifying (state=${CURRENT:-new})"
    "$AUTO_ROOT/classify-issue.sh" "$NUM" || true
    CLASSIFIED=$((CLASSIFIED+1))
  fi
done < <(echo "$ISSUES_JSON" | jq -c '.[]')

# 2. Pick the most-recently-marked-ready issue (by state-file mtime) so
# newly-ready issues don't starve behind older ones.
READY_ISSUE=""
READY_FILE=""
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  if [[ "$(get_state_kv "$f" status)" == "ready" ]]; then
    READY_FILE="$f"; break
  fi
done < <(find "$STATE_DIR" -maxdepth 1 -name 'issue-*.state' -printf '%T@ %p\n' \
         | sort -rn | awk '{ $1=""; sub(/^ /,""); print }')
[[ -n "$READY_FILE" ]] && READY_ISSUE="$(basename "$READY_FILE" .state | sed 's/^issue-//')"

if [[ -n "$READY_ISSUE" ]]; then
  log "step 2: working on issue #$READY_ISSUE"
  "$AUTO_ROOT/work-on-issue.sh" "$READY_ISSUE" || log "work-on-issue exited nonzero"
else
  log "step 2: no ready issues"
fi

# 3. Handle PR comments on open auto-PRs.
log "step 3: scanning open auto-PRs"
while read -r row; do
  PR="$(echo "$row" | jq -r '.number')"
  log "checking PR #$PR"
  "$AUTO_ROOT/handle-pr-comments.sh" "$PR" || log "handle-pr-comments exited nonzero for #$PR"
done < <(gh pr list --state open --limit 30 --json number,headRefName,isDraft \
  | jq -c --arg prefix "$AUTO_BRANCH_PREFIX" '.[] | select(.headRefName | startswith($prefix))')

log "========== cycle end =========="
