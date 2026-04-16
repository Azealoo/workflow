#!/usr/bin/env bash
# Address new review comments on an auto-opened PR.
# Usage: handle-pr-comments.sh <pr_number>
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR="${1:?pr number required}"
is_numeric "$PR" || die "pr-comments: pr id must be numeric, got: $PR"
STATE_FILE="$(state_file_for_pr "$PR")"

cd "$REPO_ROOT"

if ! git diff --quiet || ! git diff --cached --quiet; then
  log "pr-comments: repo has uncommitted changes, skipping PR #$PR"
  exit 1
fi

log "pr-comments: fetching PR #$PR"
PR_JSON="$(gh pr view "$PR" --json number,headRefName,state,isDraft,labels)"
STATE="$(echo "$PR_JSON" | jq -r '.state')"
if [[ "$STATE" != "OPEN" ]]; then
  log "pr-comments: PR #$PR is $STATE, skipping"
  exit 0
fi

LABELS_JSON="$(echo "$PR_JSON" | jq -c '.labels')"
if has_skip_label "$LABELS_JSON" "${SKIP_PR_LABELS[@]}"; then
  log "pr-comments: PR #$PR has a skip label, ignoring"
  exit 0
fi

BRANCH="$(echo "$PR_JSON" | jq -r '.headRefName')"
if [[ "$BRANCH" != ${AUTO_BRANCH_PREFIX}* ]]; then
  log "pr-comments: PR #$PR not on an auto branch, skipping"
  exit 0
fi

# Pull review + issue comments. Track two cursors (comments vs reviews) so the
# id namespaces don't collide. Comments from non-trusted authors are IGNORED
# entirely (never drive Claude) but still advance the cursor so we don't
# re-scan them next cycle.
LAST_C="$(get_state_kv "$STATE_FILE" last_seen_comment_id)"; LAST_C="${LAST_C:-0}"
LAST_R="$(get_state_kv "$STATE_FILE" last_seen_review_id)";  LAST_R="${LAST_R:-0}"

RAW_JSON="$(gh pr view "$PR" --json comments,reviews)"

COMMENTS_JSON="$(echo "$RAW_JSON" | jq --argjson sc "$LAST_C" --argjson sr "$LAST_R" '
  [ (.comments // [])[] | select(.id > $sc) | {kind:"c", id, author:.author.login, assoc:(.authorAssociation // "NONE"), body} ] +
  [ (.reviews  // [])[] | select(.id > $sr) | {kind:"r", id, author:.author.login, assoc:(.authorAssociation // "NONE"), body:(.body // "(review submitted, no body)")} ]
  | sort_by(.id)
')"

# Advance cursors for EVERYTHING we saw, trusted or not.
NEW_MAX_C="$(echo "$RAW_JSON" | jq '[.comments[]?.id] | max // 0')"
NEW_MAX_R="$(echo "$RAW_JSON" | jq '[.reviews[]?.id]  | max // 0')"

COUNT="$(echo "$COMMENTS_JSON" | jq 'length')"
if [[ "$COUNT" -eq 0 ]]; then
  log "pr-comments: no new comments on PR #$PR"
  [[ "$NEW_MAX_C" -gt "$LAST_C" ]] && write_state_kv "$STATE_FILE" last_seen_comment_id "$NEW_MAX_C"
  [[ "$NEW_MAX_R" -gt "$LAST_R" ]] && write_state_kv "$STATE_FILE" last_seen_review_id  "$NEW_MAX_R"
  exit 0
fi

# Only repo-trusted authors can drive Claude. On a public repo any random user
# can comment — we refuse to pipe their text into a bypassPermissions session.
SELF="$(gh api user --jq '.login')"
FILTERED="$(echo "$COMMENTS_JSON" | jq --arg self "$SELF" '
  [ .[]
    | select(.author != $self)
    | select(.assoc == "OWNER" or .assoc == "COLLABORATOR" or .assoc == "MEMBER")
    | select((.body // "") | length > 0)
  ]')"
FCOUNT="$(echo "$FILTERED" | jq 'length')"

if [[ "$FCOUNT" -eq 0 ]]; then
  log "pr-comments: no actionable trusted comments on PR #$PR (saw $COUNT untrusted/ignored)"
  [[ "$NEW_MAX_C" -gt "$LAST_C" ]] && write_state_kv "$STATE_FILE" last_seen_comment_id "$NEW_MAX_C"
  [[ "$NEW_MAX_R" -gt "$LAST_R" ]] && write_state_kv "$STATE_FILE" last_seen_review_id  "$NEW_MAX_R"
  exit 0
fi

COMMENTS_TEXT="$(echo "$FILTERED" | jq -r '.[] | "@\(.author) [\(.assoc)]: \(.body)\n"')"

log "pr-comments: checking out $BRANCH"
git fetch origin --quiet
git checkout "$BRANCH" --quiet
git pull --ff-only origin "$BRANCH" --quiet

BEFORE_SHA="$(git rev-parse HEAD)"

PROMPT="$(cat "$PROMPTS_DIR/pr-comments.md")"
PROMPT="${PROMPT//\{\{PR_NUMBER\}\}/$PR}"
PROMPT="${PROMPT//\{\{COMMENTS\}\}/$COMMENTS_TEXT}"

log "pr-comments: invoking Claude for PR #$PR"
set +e
RESPONSE="$(claude -p "$PROMPT" \
  --permission-mode bypassPermissions \
  --allowedTools "Read,Write,Edit,Glob,Grep,Bash" \
  --disallowedTools "$CLAUDE_DENYLIST" \
  --output-format text \
  --max-budget-usd 3.00 \
  --no-session-persistence 2>&1)"
CLAUDE_EXIT=$?
set -e

printf '%s\n' "$RESPONSE" | tail -20

# Discard uncommitted/untracked leftovers before any bailout. Otherwise dirty
# state would follow us back to main on checkout.
git reset --hard HEAD --quiet 2>/dev/null || true
git clean -fd --quiet 2>/dev/null || true

# Only treat as BLOCKED if Claude emitted it as its final non-empty line —
# avoids matching "BLOCKED:" appearing inside a code block or quoted comment.
LAST_LINE="$(printf '%s\n' "$RESPONSE" | awk 'NF {last=$0} END {print last}')"
if [[ "$LAST_LINE" == BLOCKED:* ]]; then
  log "pr-comments: BLOCKED on PR #$PR; leaving state unchanged"
  git checkout main --quiet
  exit 1
fi

if [[ "$CLAUDE_EXIT" -ne 0 ]]; then
  log "pr-comments: claude exited $CLAUDE_EXIT; leaving state unchanged"
  git checkout main --quiet
  exit 1
fi

AFTER_SHA="$(git rev-parse HEAD)"
if [[ "$BEFORE_SHA" != "$AFTER_SHA" ]]; then
  FORBIDDEN="$(forbidden_paths_in_range "$BEFORE_SHA" "$AFTER_SHA" || true)"
  if [[ -n "$FORBIDDEN" ]]; then
    log "pr-comments: PR #$PR commits touched forbidden paths, refusing to push:"
    while IFS= read -r p; do log "  $p"; done <<< "$FORBIDDEN"
    git reset --hard "$BEFORE_SHA" --quiet
    git checkout main --quiet
    exit 1
  fi
  git push origin "$BRANCH" --quiet
  log "pr-comments: pushed updates to $BRANCH"
else
  log "pr-comments: no changes were made"
fi

[[ "$NEW_MAX_C" -gt "$LAST_C" ]] && write_state_kv "$STATE_FILE" last_seen_comment_id "$NEW_MAX_C"
[[ "$NEW_MAX_R" -gt "$LAST_R" ]] && write_state_kv "$STATE_FILE" last_seen_review_id  "$NEW_MAX_R"
git checkout main --quiet
