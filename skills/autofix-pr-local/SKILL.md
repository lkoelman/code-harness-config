---
name: autofix-pr-local
description: Watch the current branch's pull request and fix failing CI checks, review comments, and base-branch conflicts locally, committing one fix per issue. Use for "autofix my PR", "watch this PR and fix what breaks", or shepherding an open PR to green without a cloud session.
argument-hint: --max-attempts <N> [--mode fix-local|fix-push|full-auto] [--only checks,reviews,bots,conflicts] [--pr <n>]
---

## When to use me

Use this skill when there is an **open pull request** that needs shepherding: CI is failing, reviewers (human or bot) have left comments, or the base branch has moved ahead. The skill loops — collect signals, fix the highest-priority one, commit, verify — until the PR is clean or the attempt budget runs out.

Do not use this skill to open a PR (that is `github-cli`), to review someone else's PR, or to merge a PR.

## Parameters

Read these from the user's invocation text.

| Flag | Default | Meaning |
|---|---|---|
| `--max-attempts <N>` | **none — required** | Hard cap on fix-and-verify cycles. |
| `--mode fix-local\|fix-push\|full-auto` | `fix-local` | How far to go: commit only / also push / also reply to threads. |
| `--only <triggers>` | all | Comma-separated subset of `checks,reviews,bots,conflicts`. |
| `--skip <triggers>` | none | Same vocabulary, subtractive. Applied after `--only`. |
| `--pr <n>` | PR of the current branch | Which PR to work. |
| `--interval <sec>` | `30` | Poll interval when waiting for PR activity. |

Trigger vocabulary: `checks` = failing CI checks; `reviews` = review comments from humans; `bots` = review comments from bot reviewers (CodeRabbit, Copilot, Sonar, …); `conflicts` = merge conflicts and base-branch drift.

**`--max-attempts` is mandatory.** If the invocation does not contain it, print this and stop — change nothing, run no `git` or `gh` write commands:

```
autofix-pr-local requires an attempt budget.

  /autofix-pr-local --max-attempts 5 [--mode fix-local|fix-push|full-auto]
                    [--only checks,reviews,bots,conflicts] [--pr <n>]
```

If `--mode` is absent, use `fix-local` and say so in the opening summary, so the user knows nothing will be pushed.

## Preflight

Run these before any fix. Abort with a one-line reason if any fails.

```bash
gh auth status
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

# Resolve the PR. Omit the number to use the current branch's PR.
gh pr view [<pr>] --json number,state,baseRefName,headRefName,url,isDraft

# Refuse to run on a dirty worktree — uncommitted work would contaminate fix commits.
git status --porcelain
```

- No PR, or `state != OPEN` → abort.
- `git status --porcelain` non-empty → abort and tell the user to commit or stash first.
- Review triggers enabled but `gh pr-review` missing (`gh extension list`) → abort with `gh extension install agynio/gh-pr-review`.
- Record the starting commit (`git rev-parse HEAD`) so the final report can list exactly what this run added.

Then post a one-paragraph opening summary: PR number and URL, mode, active triggers, attempt budget.

## Signal collection

One pass over all four signals. These are the only commands needed — both waiting strategies below reuse them.

```bash
# 1. Checks. bucket ∈ pass | fail | pending | skipping | cancel
gh pr checks <pr> --json name,bucket,link,workflow

# 2. Unresolved inline review threads (thread ids come from here)
gh pr-review review view --pr <pr> -R "$REPO" --unresolved \
  | jq '.reviews[].comments[]? | select(.is_resolved == false)'

# 3. Review comments with author classification
gh api "repos/$REPO/pulls/<pr>/comments" \
  --jq '.[] | {id, login: .user.login, type: .user.type, path, body}'

# 4. Mergeability. CONFLICTING → conflicts; BEHIND/DIRTY → base drift
gh pr view <pr> --json mergeable,mergeStateStatus
```

A comment is from a **bot** when `.user.type == "Bot"` or its login ends in `[bot]`; everything else is a **human**. Use that split to honour `--only bots` / `--skip reviews`.

## Priority order

Work one item per cycle, in this order:

1. **`conflicts`** — mergeability first. A `CONFLICTING`, `BEHIND`, or `DIRTY` branch makes CI results stale and pushes unreliable, so nothing downstream is trustworthy until it is resolved.
2. **`checks`** — objective failures, cheapest to verify.
3. **`reviews` / `bots`** — judgement calls, done last and with the most context available.

## Fixing each signal

### Failing check

```bash
# The check's `link` looks like .../actions/runs/<run-id>/job/<job-id>
gh run view <run-id> --log-failed
```

Read the failing step's output, reproduce locally where the repo makes that possible (the same test, lint, or build command), fix the cause, and re-run that local command before committing. If the failing check is **not** a GitHub Actions run (CircleCI, Buildkite, an external status), there is no `gh run` for it: report the check name and its `link`, skip it, and do not guess at the cause from the check name alone.

### Conflicts / base drift

```bash
git fetch origin
git merge origin/<base>
```

**Merge, not rebase.** Rebasing a pushed branch requires a force-push, which is off-limits unless the user explicitly asked for it in the invocation. If the user did ask for a rebase, do it, but say plainly that the follow-up push will be a force-push and confirm before running it.

### Review comments

Read the whole thread before acting — a later comment often supersedes an earlier one. Make the smallest change that genuinely addresses the point. If a comment is a question, or you disagree with it, do not invent a code change: leave it for the user and list it in the final report.

## Commit discipline

**One commit per logically separate issue**, so each fix can be reverted or cherry-picked on its own. Two failing checks with the same root cause are one issue; two unrelated review comments are two commits.

- Never amend, squash, or rewrite existing commits. Never force-push.
- Subjects: `fix(ci): <check-name> — <cause>`, `review: <what changed> (<reviewer>)`, `merge: bring in <base>`.
- Name the check or thread id in the commit body so each commit traces back to what prompted it.
- Never skip hooks (`--no-verify`).

## Mode behaviour

| Mode | Commits | Pushes | Replies to threads |
|---|---|---|---|
| `fix-local` | yes | no | no |
| `fix-push` | yes | after each commit | no |
| `full-auto` | yes | after each commit | yes |

In `full-auto`, reply to each thread that was actually addressed, naming the commit:

```bash
gh pr-review comments reply -R "$REPO" --pr <pr> --thread-id <thread-id> \
  --body "Addressed in <sha>: <one line>"
```

Never reply to or resolve a thread you did not actually address. In `fix-local` and `fix-push`, stay silent on the PR entirely.

## Waiting for PR activity

After pushing (or, in `fix-local`, once there is nothing left to fix locally), wait for the PR to change. Pick whichever branch applies to the harness you are running in.

### If a background event-monitor is available

Claude Code exposes a `Monitor` tool that streams a script's stdout lines back as notifications. Arm **one** persistent monitor for this PR and keep working; events arrive as they happen.

```bash
PR=<pr>; INTERVAL=<interval>; prev=""
while true; do
  checks=$(gh pr checks "$PR" --json name,bucket 2>/dev/null || true)
  state=$(gh pr view "$PR" --json state,mergeable,mergeStateStatus,reviews,comments 2>/dev/null || true)
  # A transient API failure is not an event — skip the tick rather than report nulls.
  if [ -z "$checks" ] || [ -z "$state" ]; then sleep "$INTERVAL"; continue; fi
  cur=$( { jq -r '.[] | select(.bucket != "pending") | "check \(.name): \(.bucket)"' <<<"$checks";
           jq -r '"merge: \(.mergeable)/\(.mergeStateStatus)", "state: \(.state)",
                  "comments: \((.comments|length) + (.reviews|length))"' <<<"$state"; } | sort )
  comm -13 <(printf '%s\n' "$prev") <(printf '%s\n' "$cur")
  prev="$cur"
  sleep "$INTERVAL"
done
```

Emit lines for **every terminal state**, not just failures — a monitor that only greps for failures is silent when a run is cancelled or the PR is closed, and silence is indistinguishable from "still running". Stop the monitor (`TaskStop`) as soon as a stop condition is met; do not leave it armed.

### Otherwise (portable fallback)

Block in the foreground:

```bash
# 0   = all checks passed
# 124 = the timeout fired, checks still running — run it again
# 8   = checks still pending; anything else non-zero = a check failed or was cancelled
timeout 540 gh pr checks <pr> --watch --fail-fast --interval <interval>
```

The `540` bound keeps the call inside the 600-second cap some harnesses impose on a single shell command; if it times out, simply run it again. When it returns, re-run signal collection and diff against the previous pass to spot new review comments — `gh pr checks --watch` only tracks checks.

Push-style delivery is possible via the `cli/gh-webhook` extension (`gh webhook forward`), but it is not the default here: it needs an extra extension, repo-admin rights to register the webhook, and a local HTTP receiver, all to improve on a 30-second poll.

## Attempt accounting

Keep state in the git directory, where it is never committed and stays correct inside worktrees:

```bash
STATE="$(git rev-parse --git-dir)/autofix-pr-local/state.json"
```

Hold: `attempts_used`, `max_attempts`, `mode`, `pr`, `start_commit`, `commits` (sha + what it fixed), `check_signatures` (check name → the error signature last seen), and `handled_threads` (thread ids already addressed). Read it at start, so a re-invocation after an interruption resumes rather than double-fixing.

One **attempt** = one fix-and-verify cycle, regardless of which signal it addressed. Stop when `attempts_used` reaches `--max-attempts`.

**No-progress guard:** before working a failing check, compare its error signature (the failing step plus the first distinctive error line) with `check_signatures`. If it matches — the check failed the same way after a fix — stop working that check, mark it as needing human attention, and move to the next signal. This prevents one unfixable failure from consuming the whole budget.

## Stopping

Stop and report when any of these holds:

- **Clean** — every check is `pass`/`skipping`, no unresolved threads remain, and mergeability is not `CONFLICTING`/`BEHIND`/`DIRTY`. This is the success condition.
- Attempt budget exhausted.
- Every remaining item is blocked by the no-progress guard, is a non-Actions check, or needs a human decision.
- The PR was merged or closed by someone else.

Then disarm any monitor and report:

- Commits created, with SHAs and one line each on what they fixed.
- Items fixed, grouped by trigger.
- Items left, each with the reason (needs a human call, non-Actions check, repeated failure, budget).
- Attempts used out of the budget, and — in `fix-local` — the reminder that nothing was pushed.

## Guardrails

- **Never make a failure go green by weakening what caught it.** No deleting or skipping tests, loosening lint rules, adding blanket ignores, or editing CI config to stop a check running. If the only way to green is to weaken a check, stop and report that.
- Keep every edit inside the scope of this PR. Do not opportunistically refactor.
- Do not touch other branches, and never push to the base branch.
- Do not comment on the PR below `full-auto`.
- Report honestly: a check you could not fix is a check you could not fix, not "addressed".
