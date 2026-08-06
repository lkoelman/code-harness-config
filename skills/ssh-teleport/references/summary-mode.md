# `--summary` mode

Read this when `--summary` is passed, during the preflight — before the opening summary, since even that paragraph differs. It replaces steps 5, 6's second half and 7 of `SKILL.md`, and carries this mode's report template and failure modes.

The point of the mode is to hand off without any Claude-specific state: the target gets the repo, the dirty files and a written handoff note, and nothing under `~/.claude` there is touched at all. That is why `session-layout.md` is the wrong file to consult for a `--summary` run — there is no transcript, no encoded project directory, and so no session-layout problem to have.

## What changes

| Step | `--summary` mode |
|---|---|
| 1 (probe) | Add `--require rsync,jq,git`. This is the only mode that does not need `claude` on the target, but `remote-setup.sh` uses `jq` and `git` in every mode, and its `worktree` and `check-repo` subcommands both run here. |
| 1 (checks) | `sessionLive` and the `claudeVersion` skew warning do not apply — no transcript is going to land. |
| 2, 3, 4 | Unchanged. `${SID%%-*}` is still a fine, harmless worktree suffix even though nothing Claude-specific is keyed by it. |
| 5 | No script. Write the handoff note yourself, per "The handoff note" below, to a file under `$SCRATCH`. |
| 6 | Same working-tree rsync and same NUL-separated deletion pass. Instead of the staged session, push the one file. |
| 7 | No `register` — this mode never writes to `~/.claude.json`, so there is no trust dialog to pre-clear and no history to append. Run `check-repo` instead of `verify`. |

Step 6's second half:

```bash
rsync -az "$SCRATCH/TELEPORT-<datetime>.md" "$DEST:$WORKTREE/"
```

Step 7:

```bash
ssh "$DEST" bash -s -- check-repo --path "$WORKTREE" --commit "$COMMIT" \
    --summary-file "TELEPORT-<datetime>.md" \
    < "$SKILL_DIR/scripts/remote-setup.sh"
```

It exits 7 if the worktree, its commit, or the summary file is not as expected. Report which of `worktree`/`commitMatches`/`summaryPresent` came back false rather than declaring success.

With `--dry-run`: run the preflight and step 1, draft the summary content, print the plan *and the draft note* so the user can review it, and stop.

## The handoff note

Nothing scripted can write this file — you write it yourself, from what you already know of this conversation, the way `/compact` distills a conversation into a summary rather than reading the transcript back to derive one.

**Filename and placement:** `TELEPORT-<datetime>.md`, with `<datetime>` from `date +%Y%m%d-%H%M%S` (e.g. `TELEPORT-20260806-143205.md`) so it sorts chronologically and is safe on every filesystem. Write it under `$SCRATCH` and push it straight into the worktree root in step 6 — never into this repo's own working tree, since it is not something to leave behind on the source machine.

**Audience:** a fresh Claude Code session with no memory of this conversation, opened by whoever is picking up the work — possibly you on the target machine, possibly a teammate. Write it as a handoff note to that reader, not as a log of what you did. A raw todo-list dump or a truncated tool-call transcript both fail this test; a paragraph that reorients someone who has never seen this conversation passes it.

Use this structure, adapting to what actually happened rather than forcing every section to be non-empty:

```markdown
# Teleport handoff — <short description of the task>

Generated <date> from `<source host>:<source repo path>`, branch `<branch>`, commit `<short sha>`.

## Objective

What this session was trying to accomplish, and why — the request as the user framed it,
plus any scope or constraints that shaped the approach.

## Done

What changed and the reasoning behind it — not a commit-by-commit log (git already has that),
but the decisions that would not be obvious from reading the diff: why this approach over an
alternative, what was ruled out and why, anything discovered along the way that shaped later choices.

## Current state

What's committed, what's still uncommitted (this teleport sends the uncommitted files, but say
what they are), and what has and hasn't been verified — tests run, commands tried, what passed.

## Next steps

The concrete next actions, as a checklist ordered by what should happen first.

## Watch out for

Anything a fresh session would otherwise rediscover the hard way: a gotcha hit and worked around,
a constraint that is not visible in the code, a dead end already ruled out.
```

Skip a section outright rather than padding it — an early-stage handoff may have nothing yet for "Current state", and a completed one may have nothing for "Watch out for". Never include credentials, tokens, or secrets, even ones that only appeared in passing.

## What travels, and what does not

Only two things travel, and nothing under `~/.claude` on the target is touched — no transcript, no subagent data, no file history, no task state, no plan file, no `~/.claude.json` edit:

| Source | Destination | Why |
|---|---|---|
| modified, staged and untracked files | the worktree | Same rsync as default mode — the target sees the tree this session was reasoning about. |
| the handoff note you wrote | `<worktree>/TELEPORT-<datetime>.md` | The one thing that stands in for the session itself. |

The limits worth stating: **which hunks were staged is not preserved**, same as default mode, and the note is only as good as what you put in it — it cannot answer a question the reader has that you did not anticipate.

## Stopping

Stop when `check-repo` passes, when a step aborts, or when the user redirects. Report with this template:

```
## ssh-teleport --summary: <short description> → <host>

Worktree:  <user>@<host>:<worktree path>  (branch <branch>)
Sent:      <n> uncommitted files, TELEPORT-<datetime>.md
Left:      <item> — <why>

Pick it up there:

  ssh -t <host> 'cd <worktree path> && cat TELEPORT-<datetime>.md'

  # then start a fresh session, or in two steps:
  ssh <host>
  cd <worktree path>
  claude

No Claude session, transcript, or ~/.claude state was copied — only the repo and the handoff note.
```

## When it does not land

`troubleshooting.md`'s "Reaching `origin` from the target", "The worktree" and "The working tree does not match" sections all apply here, since both modes create a worktree and rsync the same dirty files. Its session-resume and trust sections do not. These are this mode's own:

**`error: jq is required` or `error: git is required` from `remote-setup.sh`** — the probe was run with a `--require` list that left one of them out. Both are needed on the target in every mode; the correct list here is `rsync,jq,git`.

**`error: check-repo needs --path and --commit`** — a plain usage error; both flags are required and there is no default for either.

**`check-repo` exits 7 with `worktree: false`.** The path is not a git worktree at all — `worktree` (step 4) did not run, ran against a different path than what `check-repo` was given, or something removed the `.git` file inside it after the fact. Confirm with `git -C <path> rev-parse --git-dir` on the target directly.

**`check-repo` exits 7 with `commitMatches: false`.** `HEAD` in the worktree is not the commit the teleport created it at. This should not happen from the skill's own steps, since nothing in `--summary` mode commits — if it does, something else on the target (a person, another process) moved that worktree's `HEAD` between step 4 and this check. It is not caused by the rsynced dirty files: those change the working tree and the index, never `HEAD`.

**`check-repo` exits 7 with `summaryPresent: false`.** The single-file rsync of the handoff note either did not run or landed at the wrong name — check that the `--summary-file` argument matches the exact filename used in the `rsync` command in step 6, including the datetime.

**The handoff note reads as generic or unhelpful.** Not a script bug — there is no script involved in writing it. If it does not orient the next reader, the fix is to rewrite it with more of what "The handoff note" above asks for, not to look for a technical cause.

Diagnosing from the target, without a session to check:

```bash
ssh <host> bash -s -- check-repo --path <worktree> --commit <sha> \
    --summary-file "TELEPORT-<datetime>.md" < scripts/remote-setup.sh
```
