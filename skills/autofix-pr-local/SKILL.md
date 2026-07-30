---
name: autofix-pr-local
description: Watch the current branch's pull request and fix failing CI checks, review comments, and base-branch conflicts locally, committing one fix per issue. Use whenever CI is red on a PR, a reviewer or review bot has left comments to address, the branch has fallen behind its base, or the user asks to "autofix my PR", "watch this PR and fix what breaks", or shepherd an open PR to green without a cloud session.
argument-hint: --max-attempts <N> [--mode fix-local|fix-push|full-auto] [--only checks,reviews,bots,conflicts] [--pr <n>]
---

## When to use me

Use this skill when an **open pull request** needs shepherding: CI is failing, reviewers (human or bot) left comments, or the base branch moved ahead. The skill loops — collect signals, fix the highest-priority one, commit, verify — until the PR is clean or the attempt budget runs out.

Not for opening a PR (that is `github-cli`), reviewing someone else's PR, or merging.

## Parameters

| Flag | Default | Meaning |
|---|---|---|
| `--max-attempts <N>` | **none — required** | Hard cap on fix-and-verify cycles. |
| `--mode fix-local\|fix-push\|full-auto` | `fix-local` | Commit only / also push / also reply to threads. |
| `--only <triggers>` | all | Subset of `checks,reviews,bots,conflicts`. |
| `--skip <triggers>` | none | Same vocabulary, subtractive, applied after `--only`. |
| `--pr <n>` | PR of the current branch | Which PR to work. |
| `--interval <sec>` | `30` | Poll interval while waiting. |

`checks` = failing CI; `reviews` = human review comments; `bots` = review comments from bot reviewers; `conflicts` = merge conflicts and base drift.

**`--max-attempts` is required** — an unbounded fix loop on a failure it cannot fix will spend the session and the token budget on nothing. If the invocation omits it, print this and stop without running any `git` or `gh` write command:

```
autofix-pr-local requires an attempt budget.

  /autofix-pr-local --max-attempts 5 [--mode fix-local|fix-push|full-auto]
                    [--only checks,reviews,bots,conflicts] [--pr <n>]
```

If `--mode` is omitted, use `fix-local` and say so up front, so the user knows nothing will be pushed.

## Bundled scripts

Three scripts do the mechanical work. They sit next to this SKILL.md; if the harness told you the path it loaded this skill from, use that, otherwise:

```bash
SKILL_DIR=$(for d in "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.gemini/skills" \
                     "$HOME/.config/opencode/skills" "$HOME/.pi/agent/skills"; do
              [ -f "$d/autofix-pr-local/SKILL.md" ] && { echo "$d/autofix-pr-local"; break; }
            done)
```

| Script | Purpose |
|---|---|
| `scripts/pr-signals.sh --pr <n>` | All four signals as one JSON document. Run at the start of every cycle. |
| `scripts/poll-pr.sh --pr <n> [--once]` | One line per change on the PR; silence means nothing changed. |
| `scripts/pr-state.sh <cmd>` | Attempt budget, error signatures, handled threads, commits made. |

If you cannot locate them, `references/fallbacks.md` documents the raw `gh` commands they wrap — but prefer the scripts: they normalise the output you branch on, and their exit codes carry the loop's control flow.

## The loop

**Preflight**, once:

```bash
gh auth status
gh pr view [<n>] --json number,state,baseRefName,headRefName,url,isDraft
git status --porcelain          # must be empty
"$SKILL_DIR/scripts/pr-state.sh" init --pr <n> --max-attempts <N> --mode <mode>
```

Abort if there is no open PR, or if the worktree is dirty — uncommitted work would be swept into fix commits. Then post a one-paragraph opening summary: PR number and URL, mode, active triggers, attempt budget. `init` on the same PR resumes an existing tally rather than resetting it, so an interrupted run does not re-fix what it already fixed.

**Each cycle:**

1. `pr-signals.sh --pr <n>` and read the fields you need: `needsBaseSync`, `failingChecks`, `unresolvedThreads` (each carries `isBot`), `counts`.
2. Pick **one** item, in this order — `conflicts` → `checks` → `reviews`/`bots`. Mergeability comes first because a `BEHIND`/`DIRTY` branch makes check results stale and pushes unreliable; objective check failures come before judgement calls.
3. `pr-state.sh attempt` — exit 1 means the budget is spent, so stop and report.
4. Fix it:
   - **Base sync** — `git fetch origin && git merge origin/<base>`. Merge, not rebase; see `references/fallbacks.md`.
   - **Failing check** — `gh run view <runId> --log-failed`, read the failing step, reproduce locally where the repo allows, fix, re-run that local command. Then `pr-state.sh signature <check> "<failing step + first distinctive error line>"`. **Exit 3 means the check failed the same way as last time**: the fix did not work, so stop working that check and move on rather than spending the rest of the budget on it.
   - **Review comment** — read the whole thread first; a later comment often supersedes an earlier one. Make the smallest change that genuinely addresses the point. `pr-state.sh thread-seen <id>` first to skip anything already handled.
5. Commit (below), record it with `pr-state.sh commit <sha> "<what it fixed>"`, and push if the mode says so.
6. Wait for the PR to change — see `references/waiting.md`, which covers both the background-monitor and foreground-polling branches.

## Commit discipline

**One commit per logically separate issue**, so each fix can be reverted or cherry-picked on its own. Two failing checks with one root cause are one commit; two unrelated review comments are two.

Subjects: `fix(ci): <check-name> — <cause>`, `review: <what changed> (<reviewer>)`, `merge: bring in <base>`. Name the check or thread id in the body so every commit traces back to what prompted it.

Do not amend, squash, or force-push: this branch is published, and rewriting it breaks anyone who has pulled it and destroys the per-issue revertability that is the point of the above. `AGENTS.md` conventions (no `--no-verify`, no destructive git without approval) apply here as everywhere.

## Modes

| Mode | Commits | Pushes | Replies to threads |
|---|---|---|---|
| `fix-local` | yes | no | no |
| `fix-push` | yes | after each commit | no |
| `full-auto` | yes | after each commit | yes |

In `full-auto`, reply only to threads you actually addressed, naming the commit:

```bash
gh pr-review comments reply -R "$REPO" --pr <n> --thread-id <id> --body "Addressed in <sha>: <one line>"
```

Then `pr-state.sh thread-done <id>`. Below `full-auto`, stay silent on the PR — an unexpected bot comment on someone's PR is noise they did not ask for.

## Stopping

Stop when the PR is **clean** (every check `pass`/`skipping`, no unresolved threads, `needsBaseSync` false), when `pr-state.sh attempt` reports the budget spent, when every remaining item is stalled or needs a human, or when the PR is merged or closed by someone else. Disarm any monitor, then report using this template:

```
## autofix-pr-local: PR #<n> — <clean | budget spent | needs attention>

Commits (<count>):
  <sha>  <what it fixed>

Fixed:
  - <trigger>: <item>

Left:
  - <item> — <why: needs a human call / non-Actions check / no progress / budget>

Attempts: <used>/<max>   Mode: <mode>   Pushed: <yes|no>
```

## Guardrails

- **Never make a failure go green by weakening what caught it** — no deleting or skipping tests, loosening lint rules, adding blanket ignores, or editing CI config so a check stops running. That converts a visible problem into an invisible one, which is worse than the red check. If the only route to green is to weaken a check, stop and say so.
- Keep edits inside this PR's scope; do not opportunistically refactor.
- Never push to the base branch or touch other branches.
- Report honestly: a check you could not fix is "left", not "addressed". The user is trusting this loop precisely because they are not watching it.
