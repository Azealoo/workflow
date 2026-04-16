# workflow

Unattended GitHub issue → PR automation. Every 15 minutes a systemd timer wakes
up, asks Claude to triage the open issues assigned to you, implements the ones
that are unambiguous on a new branch, opens a draft PR, and — on subsequent
cycles — responds to review feedback from repo collaborators.

It's meant to run as **you** against **your own repo**, on a box you trust.
It is not a multi-tenant service.

## What each cycle does

`cycle.sh` runs three steps under a `flock` so two cycles never overlap:

1. **Classify new issues.** Lists open issues assigned to `@me`, and for each
   one that hasn't been looked at (or whose `updatedAt` has changed since last
   time) asks Claude `READY` vs `NEEDS_INFO`. A bounded number per cycle
   (`MAX_CLASSIFY_PER_CYCLE=10`) to cap spend.
   - `READY` → state file gets `status=ready` plus the classifier's summary.
   - `NEEDS_INFO` → a draft comment is written to
     `.automation/drafts/issue-N.md`. Nothing is posted automatically — you
     review and post it with `gh issue comment`.

2. **Implement one ready issue.** Picks the most-recently-marked-ready issue
   (by state-file mtime, so fresh work doesn't starve behind old), creates
   `auto/issue-N`, runs Claude with a low-trust prompt, commits, pushes, and
   opens a draft PR.

3. **Address review comments.** For each open PR whose branch starts with
   `auto/issue-`, pulls new comments/reviews. Only comments from authors with
   `authorAssociation` in {`OWNER`, `COLLABORATOR`, `MEMBER`} drive Claude;
   drive-by comments from random users are ignored but the cursor still
   advances so they aren't re-scanned forever.

## Prerequisites

- `bash`, `git`, `jq`, `wget`, `awk`, `grep` (standard Linux userland)
- [`gh`](https://cli.github.com/) authenticated to your GitHub account
  (`gh auth login`)
- [`claude`](https://docs.claude.com/en/docs/agents-and-tools/claude-code) CLI
  logged in and with budget available
- `systemd --user` available (most desktop Linux distros)
- A GitHub repo you own with issues you'd like triaged

## Install

```bash
# 1. Clone the repo wherever you want it to live.
git clone git@github.com:<you>/workflow.git ~/workflow
cd ~/workflow

# 2. Verify gh + claude work for you.
gh auth status
claude --version

# 3. Drop the systemd units in and start the timer.
mkdir -p ~/.config/systemd/user
cp systemd/workflow.service ~/.config/systemd/user/
cp systemd/workflow.timer   ~/.config/systemd/user/
#   If you cloned somewhere other than ~/workflow, edit WorkingDirectory +
#   ExecStart in workflow.service before enabling.
systemctl --user daemon-reload
systemctl --user enable --now workflow.timer

# 4. First cycle will run 2 minutes after boot; tail the log.
tail -f .automation/logs/cycle-$(date +%Y%m%d).log
```

Run a cycle on demand with `systemctl --user start workflow.service` — useful
right after you label a new issue and don't want to wait.

## Day-to-day use

1. **Open an issue on your repo** and assign it to yourself. The cycle only
   touches issues with `assignee: @me`.
2. **Wait up to 15 minutes.** On the next cycle Claude classifies it.
3. **If it's ready:** the cycle will implement it on the next tick. You'll see
   a draft PR titled with the issue title. Review the diff, click "Ready for
   review" (or close it if the attempt was wrong).
4. **If it needs info:** check `.automation/drafts/issue-N.md`, edit the
   questions if you want, then post with
   `gh issue comment N --body-file .automation/drafts/issue-N.md`. Once you
   update the issue body the next cycle re-classifies.
5. **On review feedback:** leave a review comment as yourself (or another
   collaborator). The next cycle pulls it, asks Claude to address it, and
   pushes a fix-up commit to the same branch.

## Controls

| Action | How |
|---|---|
| Pause everything | `touch .automation/PAUSE` |
| Resume | `rm .automation/PAUSE` |
| Skip one issue | Label it `no-auto`, `blocked`, `wontfix`, `duplicate`, or `question` |
| Skip one PR | Label it `no-auto` |
| Retry a blocked issue | `rm .automation/state/issue-N.state` |
| Stop the timer | `systemctl --user disable --now workflow.timer` |

## State model

Each issue and PR has a state file in `.automation/state/`. Keys used:

- `status` — one of `ready`, `pr_opened`, `needs_info`, `blocked`, `failed`,
  `no_change`, `skipped`, `closed`
- `summary` — classifier's one-line plan (written verbatim to the worker prompt
  as low-trust hint text)
- `last_issue_updated` — the issue's `updatedAt` when last classified; lets the
  cycle re-classify after you edit the issue
- `attempts` — incremented on worker failure; after 3 the status flips to
  `failed` and the issue is left alone
- `pr` — PR number for the `pr_opened` state
- `last_seen_comment_id` / `last_seen_review_id` — cursors for PR comment
  handling so we don't re-process the same feedback

State files are plain `key=value` text, safe to edit by hand.

## Security posture

Claude is invoked with `--permission-mode bypassPermissions` so it can edit
files without prompting. Issues and PR comments contain untrusted text from
the internet, so the scripts apply several defenses:

- Every untrusted span is fenced (`<issue>…</issue>`, `<comments>…</comments>`,
  `<classifier_summary_low_trust>…</classifier_summary_low_trust>`) and the
  prompt tells Claude to treat it as data, not instructions.
- PR comments drive Claude **only** if the author's `authorAssociation` is
  `OWNER`, `COLLABORATOR`, or `MEMBER`.
- `--disallowedTools` denies `WebFetch`, `WebSearch`, and a sub-pattern list
  (`Bash(curl:*)`, `Bash(gh:*)`, `Bash(python:*)`, `Bash(bash -c:*)`, …) that
  blocks shell-based network access and scripting runtimes. Whole-tool denials
  for `Write`/`Edit` are **not** reliably enforced under `bypassPermissions`,
  so see the next bullet.
- After Claude commits, `forbidden_paths_in_range` scans the commit range and
  refuses to push if any path matches `.automation/`, `.github/`,
  `.git/hooks/`, or `.claude/`. The branch is deleted locally, the issue is
  marked `blocked`, and the state file is preserved so you can see what
  happened.
- Classifier summary is stripped of CR/newlines/non-printables and capped at
  500 chars before entering the state file, so a prompt-injected classifier
  can't forge a synthetic `status=` line.

## Layout

```
.automation/
  cycle.sh                 — entrypoint, run by the systemd timer
  classify-issue.sh        — READY / NEEDS_INFO triage
  work-on-issue.sh         — implement + commit + open draft PR
  handle-pr-comments.sh    — address new review feedback
  lib.sh                   — helpers + the shared CLAUDE_DENYLIST
  prompts/                 — templates with {{…}} placeholders
  state/                   — per-issue / per-PR key=value files (gitignored)
  logs/                    — one log per day (gitignored)
  drafts/                  — NEEDS_INFO questions waiting for your review (gitignored)
  PAUSE                    — touch this file to stop the timer mid-cycle (gitignored)
systemd/
  workflow.service
  workflow.timer
CLAUDE.md                  — principles the worker must follow
```

## Troubleshooting

**Cycle doesn't start** — `systemctl --user status workflow.timer` and
`journalctl --user -u workflow.service -e`. If the service exits
`218/CAPABILITIES` you probably re-added systemd sandboxing; see the comment
in `workflow.service`.

**Worker keeps bailing with "repo has uncommitted changes"** — something
left the tree dirty. `git status`, clean it up, then the next cycle will
proceed.

**Classifier marks everything `NEEDS_INFO`** — your issues genuinely are
ambiguous. Check `.automation/drafts/issue-N.md` to see what Claude is
asking for, answer on the issue, and the next cycle will re-classify.

**A PR is stuck** — mark it `no-auto` to pause automation on it, or delete
its state file to reset cursors.

## Design notes

- Issues assigned to you, not all open issues. Drives what Claude works on
  from the GitHub UI you already use.
- Draft PRs only. You flip to ready-for-review after inspecting the diff.
- One ready issue per cycle. Keeps spend predictable and means you always
  have time to interject between attempts.
- Max 3 attempts per issue. A repeatedly-failing issue flips to `failed`
  and is left alone until you reset it.
- No auto-push from `handle-pr-comments.sh` if the diff touches forbidden
  paths — the branch is hard-reset to `BEFORE_SHA` locally and nothing
  reaches the remote.
