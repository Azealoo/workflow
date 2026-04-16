#!/usr/bin/env bash
# Classify a single issue as READY or NEEDS_INFO.
# Usage: classify-issue.sh <issue_number>
# Exits 0 if READY, 1 if NEEDS_INFO, 2 on error.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ISSUE="${1:?issue number required}"
STATE_FILE="$(state_file_for_issue "$ISSUE")"

log "classify: fetching issue #$ISSUE"
ISSUE_JSON="$(gh issue view "$ISSUE" --json number,title,body,author,labels,state,updatedAt)"

STATE="$(echo "$ISSUE_JSON" | jq -r '.state')"
if [[ "$STATE" != "OPEN" ]]; then
  log "classify: issue #$ISSUE is $STATE, skipping"
  write_state_kv "$STATE_FILE" status "closed"
  exit 1
fi

LABELS_JSON="$(echo "$ISSUE_JSON" | jq -c '.labels')"
if has_skip_label "$LABELS_JSON" "${SKIP_ISSUE_LABELS[@]}"; then
  log "classify: issue #$ISSUE has a skip label, ignoring"
  write_state_kv "$STATE_FILE" status "skipped"
  exit 1
fi

TITLE="$(echo "$ISSUE_JSON" | jq -r '.title')"
BODY="$(echo "$ISSUE_JSON" | jq -r '.body // ""')"
AUTHOR="$(echo "$ISSUE_JSON" | jq -r '.author.login')"
LABELS_TXT="$(echo "$ISSUE_JSON" | jq -r '[.labels[].name] | join(", ")')"
UPDATED="$(echo "$ISSUE_JSON" | jq -r '.updatedAt')"

PROMPT="$(cat "$PROMPTS_DIR/classify.md")"
PROMPT="${PROMPT//\{\{TITLE\}\}/$TITLE}"
PROMPT="${PROMPT//\{\{LABELS\}\}/$LABELS_TXT}"
PROMPT="${PROMPT//\{\{AUTHOR\}\}/$AUTHOR}"
PROMPT="${PROMPT//\{\{BODY\}\}/$BODY}"

log "classify: asking Claude about #$ISSUE"
RESPONSE="$(claude -p "$PROMPT" \
  --tools "" \
  --permission-mode default \
  --output-format text \
  --max-budget-usd 0.50 \
  --no-session-persistence 2>&1)" || {
  log "classify: claude invocation failed"
  exit 2
}

# Extract the JSON object from the response (tolerate whitespace/markdown).
JSON="$(echo "$RESPONSE" | sed -n 's/.*\({.*}\).*/\1/p' | head -1)"
if [[ -z "$JSON" ]]; then
  log "classify: could not parse response: $RESPONSE"
  exit 2
fi

DECISION="$(echo "$JSON" | jq -r '.decision // empty')"
case "$DECISION" in
  READY)
    log "classify: #$ISSUE READY"
    write_state_kv "$STATE_FILE" status "ready"
    write_state_kv "$STATE_FILE" last_issue_updated "$UPDATED"
    exit 0
    ;;
  NEEDS_INFO)
    QUESTIONS="$(echo "$JSON" | jq -r '.questions[]?' | sed 's/^/- /')"
    DRAFT_FILE="$DRAFTS_DIR/issue-$ISSUE.md"
    LAST_CLASSIFIED_AT="$(get_state_kv "$STATE_FILE" last_issue_updated)"
    if [[ "$LAST_CLASSIFIED_AT" != "$UPDATED" ]]; then
      {
        echo "<!-- DRAFT for issue #$ISSUE — review, edit, then post with:"
        echo "     gh issue comment $ISSUE --body-file $DRAFT_FILE  -->"
        echo ""
        echo "This issue isn't ready for automated implementation yet. Please clarify:"
        echo ""
        echo "$QUESTIONS"
      } > "$DRAFT_FILE"
      log "classify: #$ISSUE NEEDS_INFO — draft saved to $DRAFT_FILE"
      write_state_kv "$STATE_FILE" last_issue_updated "$UPDATED"
    else
      log "classify: #$ISSUE NEEDS_INFO — already drafted, skipping"
    fi
    write_state_kv "$STATE_FILE" status "needs_info"
    exit 1
    ;;
  *)
    log "classify: unexpected decision '$DECISION'"
    exit 2
    ;;
esac
