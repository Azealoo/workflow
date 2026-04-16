#!/usr/bin/env bash
# Implement a READY issue on a new branch and open a draft PR.
# Usage: work-on-issue.sh <issue_number>
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ISSUE="${1:?issue number required}"
is_numeric "$ISSUE" || die "work: issue id must be numeric, got: $ISSUE"
STATE_FILE="$(state_file_for_issue "$ISSUE")"
BRANCH="$(branch_for_issue "$ISSUE")"
MAX_ATTEMPTS=3

cd "$REPO_ROOT"

# Refuse if repo has uncommitted changes — we won't pollute user's WIP.
if ! git diff --quiet || ! git diff --cached --quiet; then
  log "work: repo has uncommitted changes, skipping #$ISSUE"
  exit 1
fi

log "work: fetching issue #$ISSUE"
ISSUE_JSON="$(gh issue view "$ISSUE" --json number,title,body,labels,state)"
STATE="$(echo "$ISSUE_JSON" | jq -r '.state')"
[[ "$STATE" == "OPEN" ]] || { log "work: issue #$ISSUE is $STATE, skipping"; exit 1; }

TITLE="$(echo "$ISSUE_JSON" | jq -r '.title')"
BODY="$(echo "$ISSUE_JSON" | jq -r '.body // ""')"
LABELS_TXT="$(echo "$ISSUE_JSON" | jq -r '[.labels[].name] | join(", ")')"

log "work: preparing branch $BRANCH"
git fetch origin --quiet
git checkout main --quiet
git pull --ff-only origin main --quiet

# Local leftover from a crashed prior attempt at THIS issue (state still
# "ready" means no PR was ever opened) — safe to discard and rebuild.
if git rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  if [[ "$(get_state_kv "$STATE_FILE" status)" == "ready" ]]; then
    log "work: removing leftover local $BRANCH from previous crashed attempt"
    git branch -D "$BRANCH" --quiet
  else
    log "work: branch $BRANCH exists locally and issue isn't ready; skipping"
    exit 1
  fi
fi

if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
  log "work: branch $BRANCH already exists on origin, skipping"
  exit 1
fi
git checkout -b "$BRANCH" --quiet

BEFORE_SHA="$(git rev-parse HEAD)"

SUMMARY="$(get_state_kv "$STATE_FILE" summary)"
[[ -z "$SUMMARY" ]] && SUMMARY="(classifier did not provide a summary)"

PROMPT="$(cat "$PROMPTS_DIR/work.md")"
PROMPT="${PROMPT//\{\{ISSUE_NUMBER\}\}/$ISSUE}"
PROMPT="${PROMPT//\{\{TITLE\}\}/$TITLE}"
PROMPT="${PROMPT//\{\{LABELS\}\}/$LABELS_TXT}"
PROMPT="${PROMPT//\{\{SUMMARY\}\}/$SUMMARY}"
PROMPT="${PROMPT//\{\{BODY\}\}/$BODY}"

ATTACHMENTS="$(download_attachments "$BODY" "$ISSUE")"
if [[ -n "$ATTACHMENTS" ]]; then
  COUNT="$(echo "$ATTACHMENTS" | wc -l)"
  log "work: #$ISSUE has $COUNT image attachment(s)"
  PROMPT+=$'\n\nATTACHMENTS — read each of these files before implementing:\n'
  while IFS= read -r p; do PROMPT+="- $p"$'\n'; done <<< "$ATTACHMENTS"
fi

bump_attempts_then_bail() {
  local reason="$1"
  local attempts
  attempts="$(get_state_kv "$STATE_FILE" attempts)"
  attempts=$(( ${attempts:-0} + 1 ))
  write_state_kv "$STATE_FILE" attempts "$attempts"
  git checkout main --quiet
  git branch -D "$BRANCH" --quiet 2>/dev/null || true
  if [[ "$attempts" -ge "$MAX_ATTEMPTS" ]]; then
    log "work: $reason on #$ISSUE (attempt $attempts/$MAX_ATTEMPTS) — marking failed"
    write_state_kv "$STATE_FILE" status "failed"
  else
    log "work: $reason on #$ISSUE (attempt $attempts/$MAX_ATTEMPTS) — will retry"
  fi
  exit 1
}

log "work: invoking Claude for #$ISSUE"
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

# Match BLOCKED only on the final non-empty line so we don't false-positive on
# a literal "BLOCKED:" inside a code block Claude produced.
LAST_LINE="$(printf '%s\n' "$RESPONSE" | awk 'NF {last=$0} END {print last}')"
if [[ "$LAST_LINE" == BLOCKED:* ]]; then
  log "work: Claude reported BLOCKED on #$ISSUE; abandoning branch"
  git checkout main --quiet
  git branch -D "$BRANCH" --quiet
  write_state_kv "$STATE_FILE" status "blocked"
  exit 1
fi

if [[ "$CLAUDE_EXIT" -ne 0 ]]; then
  bump_attempts_then_bail "claude exited $CLAUDE_EXIT"
fi

AFTER_SHA="$(git rev-parse HEAD)"
if [[ "$BEFORE_SHA" == "$AFTER_SHA" ]]; then
  log "work: no commits made for #$ISSUE — marking no_change"
  git checkout main --quiet
  git branch -D "$BRANCH" --quiet
  write_state_kv "$STATE_FILE" status "no_change"
  exit 1
fi

# Safety net: the prompt tells Claude not to touch .automation/ or .github/
# but under --permission-mode bypassPermissions the CLI does not enforce
# whole-tool denials for Write/Edit, so a prompt-injected issue could get
# Claude to modify infra files anyway. Reject the branch if it happened.
FORBIDDEN="$(forbidden_paths_in_range "$BEFORE_SHA" "$AFTER_SHA" || true)"
if [[ -n "$FORBIDDEN" ]]; then
  log "work: #$ISSUE commit touched forbidden paths, refusing to push:"
  while IFS= read -r p; do log "  $p"; done <<< "$FORBIDDEN"
  git checkout main --quiet
  git branch -D "$BRANCH" --quiet
  write_state_kv "$STATE_FILE" status "blocked"
  exit 1
fi

log "work: pushing $BRANCH"
if ! git push -u origin "$BRANCH" --quiet; then
  log "work: push failed for $BRANCH; cleaning up so next cycle can retry"
  git checkout main --quiet || true
  git branch -D "$BRANCH" --quiet 2>/dev/null || true
  bump_attempts_then_bail "git push failed"
fi

log "work: opening draft PR for #$ISSUE"
PR_BODY="Closes #$ISSUE

Implemented by workflow automation. Review the diff and mark ready-for-review if it looks correct."
PR_CREATED=0
for attempt in 1 2 3; do
  if gh pr create --draft --base main --head "$BRANCH" \
       --title "$TITLE" --body "$PR_BODY" >/dev/null 2>&1; then
    PR_CREATED=1
    break
  fi
  log "work: gh pr create attempt $attempt failed; sleep ${attempt}s then retry"
  sleep "$attempt"
done
if [[ "$PR_CREATED" -eq 0 ]]; then
  # All retries failed. Delete the remote branch so next cycle starts clean
  # rather than hitting "branch already exists on origin" forever.
  log "work: gh pr create exhausted retries; deleting remote $BRANCH"
  git push origin --delete "$BRANCH" --quiet 2>/dev/null || true
  bump_attempts_then_bail "gh pr create failed after retries"
fi
PR_NUMBER="$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number // empty')"
if [[ -z "$PR_NUMBER" ]]; then
  log "work: could not determine PR number for $BRANCH"
  git checkout main --quiet
  exit 1
fi

log "work: opened PR #$PR_NUMBER"
write_state_kv "$STATE_FILE" status "pr_opened"
write_state_kv "$STATE_FILE" pr "$PR_NUMBER"
write_state_kv "$STATE_FILE" attempts "0"

git checkout main --quiet
