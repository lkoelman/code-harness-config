---
name: ssh-teleport
description: Copy the current Claude Code session to another machine over ssh/rsync and resume it there in a git worktree, or, with --summary, sync just the repo state plus a written handoff note. Use when the user wants to move, hand off, or continue this session on a different host — "teleport this session to the gpu box", "continue this on my other machine", "send this session to <host>", "hand this off without the claude session" — or asks for the ssh and claude commands to pick this conversation up elsewhere.
harnesses: [claude]
argument-hint: --host <hostname> [--user <username>] [--repo-path <path>] [--worktree-path <path>] [--summary] [--dry-run]
---

## When to use me

Use this skill to move **this** session to another machine: transcript, subagent transcripts, saved tool results, plan file, task numbering, file history, and the working tree it was reasoning about, landing in a fresh git worktree on the target so that machine's own checkout is left alone. It ends by printing the `ssh` and `claude` commands that resume the conversation there.

Pass `--summary` when the target should get the code and a written handoff, and nothing Claude-specific — handing off to a teammate, a target that will start its own fresh Claude Code session, or any case where copying the transcript is not wanted. See "The summary document" below for what that mode sends instead.

Not for moving between directories on the *same* machine — Claude Code does that natively (`/cd` relocates the session's project storage, `EnterWorktree`/`ExitWorktree` move it into and out of a worktree, and `Ctrl+W` widens the `/resume` picker across a repo's worktrees). Not for syncing all of `~/.claude` either; that is a dotfiles job, and `./scripts/install.sh` is how this repo's skills and agents reach a machine.

## Parameters

| Flag | Default | Meaning |
|---|---|---|
| `--host <hostname>` | **none — required** | Target host: an `~/.ssh/config` alias or a hostname. |
| `--user <username>` | from `ssh -G <host>` | Login user. Required when the host has no `Host` block in `~/.ssh/config`. |
| `--repo-path <path>` | probed on the target | Existing clone of this repo there. |
| `--worktree-path <path>` | `<parent of repo>/worktrees-<repo>/<branch>` | Where the worktree is created. |
| `--summary` | off | Sync only the repo (dirty files) plus a generated `TELEPORT-<datetime>.md` handoff note. No transcript, subagent transcripts, tool results, file history, tasks, plan file, or `~/.claude.json` change travels — nothing under `~/.claude` on the target is touched at all. |
| `--dry-run` | off | Probe and stage (or draft the summary), print the plan, write nothing on the target. |

There is no flag for agent forwarding: the two commands that reach `origin` always use `ssh -A`, and nothing else does.

Fill in what is missing rather than guessing:

- **`--host`** absent → ask. Nothing else can be derived without it.
- **`--user`** absent → `probe-target.sh` reports `userFromConfig`. When that is false the user it resolved is just the local `$USER` echoed back by `ssh -G`, which is not evidence — ask.
- **`--repo-path`** absent → use `repoPath` from the probe. When it comes back empty the target has no clone of this repo in any of the usual places, so ask where to put one and clone it (step 2).
- **`--worktree-path`** absent → use `suggestedWorktreePath` from the probe, and name it in the opening summary so the user can redirect it before anything is written.

## Bundled scripts

```bash
SKILL_DIR="$HOME/.claude/skills/ssh-teleport"
```

| Script | Runs | Purpose |
|---|---|---|
| `scripts/probe-target.sh --host H [--user U] [--repo-path P] [--require LIST]` | here, one `ssh -A` round trip | Every target fact as one JSON document. Exit 2 unreachable, 3 missing one of `--require`'s dependencies (default `jq,rsync,claude`; pass `--require rsync` in `--summary` mode, which needs neither `claude` nor `jq` on the target). |
| `scripts/stage-session.sh --session-id … --target-cwd … --target-home … --target-branch … --out DIR` | here | **Default mode only.** Builds a mirror of the target's `~/.claude` with every path rewritten; prints a manifest. Exit 4 if the target path cannot be encoded. |
| `scripts/remote-setup.sh <worktree\|register\|verify\|check-repo> …` | **on the target**, streamed in | `ssh <dest> bash -s -- <cmd> … < "$SKILL_DIR/scripts/remote-setup.sh"`. Exit 5 unknown commit, 6 default-mode session would not resume, 7 `--summary` mode's `check-repo` found the worktree or the summary file wrong. |

`references/session-layout.md` explains where session state lives and why each piece travels; `references/troubleshooting.md` maps the failure modes to their actual error strings. Read them when something does not land, not up front.

## The teleport

**Preflight**, read-only, abort on any failure:

```bash
echo "$CLAUDE_CODE_SESSION_ID"      # the session being moved — do not guess this from file mtimes
git rev-parse --show-toplevel HEAD
git branch --show-current
git remote get-url origin
claude --version
ssh-add -l                          # the keys the target will borrow
```

Abort if this is not a git repository — the worktree is the whole point. Then post a one-paragraph opening summary: host and login user, target repo path, worktree path and branch, mode (default or `--summary`), session id, transcript size (default mode) or nothing to summarize yet (`--summary` mode), and how many uncommitted files will travel. That paragraph is the user's last chance to redirect before anything is written on the target.

1. **Probe.** Default mode: `probe-target.sh --host <host> [--user <u>] [--repo-path <p>]`. `--summary` mode: add `--require rsync`, since that mode never touches `claude` or `jq` on the target. Stop on exit 2 or 3.

   Default mode only: stop if `sessionLive` is true — that session id is already open on the target, and writing under a live session corrupts it. Warn but continue if `claudeVersion` differs from local in anything but the patch number: the transcript format is internal to Claude Code and changes between versions. Neither check applies to `--summary` mode, since no transcript is going to land there.

   Either mode: if `localAgentKeys` is 0 or `agentForwardingOk` is false, say so now, because steps 2 and 3 are the ones that will feel it.

2. **Settle the repo.** With `repoPath` non-empty and `originMatches` true, use it. Otherwise ask for a path and clone through the forwarded agent (below). A clone can take a while on a large repo; say what you are doing before you start it.

3. **Make the commit reachable.** If `headPresent` is false, fetch through the forwarded agent and re-probe. Still missing means the commits exist only here: **ask** before pushing anything to `origin`, and abort if the user says no. Never push as a silent side effect of a teleport.

4. **Create the worktree.**

   ```bash
   ssh "$DEST" bash -s -- worktree --repo "$REPO" --path "$WORKTREE" \
       --branch "$BRANCH" --commit "$COMMIT" --suffix "${SID%%-*}" \
       < "$SKILL_DIR/scripts/remote-setup.sh"
   ```

   It uses the session's own branch name when that name is free on the target and `<branch>.teleport-<suffix>` when it is not, either way checked out at exactly `$COMMIT`. **Take `path` and `branch` from its output, not from what you asked for** — `path` is the target's `realpath`, and `branch` is what the target is really on; default mode needs `path` exactly right for the project-directory encoding. Exit 5 means step 3 did not actually land the commit. In `--summary` mode, `${SID%%-*}` is still a fine, harmless suffix even though nothing Claude-specific is keyed by it.

5. **Prepare what travels.**

   - **Default mode:** `stage-session.sh --session-id "$SID" --target-cwd <path from step 4> --target-home <remoteHome> --target-branch <branch from step 4> --out "$SCRATCH/stage"`. Exit 4 means the worktree path cannot be encoded the way Claude Code would encode it (non-ASCII, or over 200 characters once encoded) — ask for a shorter ASCII path and redo step 4 rather than pressing on, because the transcript would land where `--resume` cannot deterministically find it. Read the manifest and keep the counts for the closing report.
   - **`--summary` mode:** no script for this one — write the handoff note yourself, following "The summary document" below, to a scratch file. Nothing under `~/.claude` is touched, so there is no encoding rule to worry about here.

6. **Push.** The working tree first, in both modes — modified, staged and untracked files that still exist, with `.git` never in the set:

   ```bash
   { git ls-files -z --modified --others --exclude-standard
     git diff --cached --name-only -z; } | sort -zu \
     | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done \
     | rsync -az --files-from=- --from0 ./ "$DEST:$WORKTREE/"
   ```

   Files deleted here but present in `HEAD` have to be removed there too, or the worktree will disagree with what the session believes:

   ```bash
   git ls-files -z --deleted | tr '\0' '\n' | sed "s|^|$WORKTREE/|" \
     | ssh "$DEST" "xargs -r -d '\n' rm -f --"
   ```

   Then, by mode:

   - **Default mode:** the staged session, which already mirrors the target's `~/.claude` layout, so there is no path arithmetic left to get wrong:

     ```bash
     rsync -az "$SCRATCH/stage/" "$DEST":
     ```

   - **`--summary` mode:** just the one file, straight into the worktree root:

     ```bash
     rsync -az "$SCRATCH/TELEPORT-<datetime>.md" "$DEST:$WORKTREE/"
     ```

7. **Register and verify.**

   - **Default mode:**

     ```bash
     ssh "$DEST" bash -s -- register --path "$WORKTREE" --session-id "$SID" \
         < "$SKILL_DIR/scripts/remote-setup.sh"
     ssh "$DEST" bash -s -- verify --path "$WORKTREE" --session-id "$SID" \
         < "$SKILL_DIR/scripts/remote-setup.sh"
     ```

     `register` merges one project key into `~/.claude.json` so the first `claude` run there does not stop on the trust dialog, and appends this session's prompt-history lines. `verify` exits 6 if the session would not resume; when it does, report which of `worktree`/`transcriptPresent`/`resumable`/`cwdMatches` came back false instead of printing resume instructions that will not work.

   - **`--summary` mode:** no `register` — this mode never writes to `~/.claude.json`, so there is no trust dialog to pre-clear and no history to append.

     ```bash
     ssh "$DEST" bash -s -- check-repo --path "$WORKTREE" --commit "$COMMIT" \
         --summary-file "TELEPORT-<datetime>.md" \
         < "$SKILL_DIR/scripts/remote-setup.sh"
     ```

     Exits 7 if the worktree, its commit, or the summary file is not as expected; report which of `worktree`/`commitMatches`/`summaryPresent` came back false rather than declaring success.

With `--dry-run`: default mode runs steps 1 and 5 only (step 5 needs a target path, so use `suggestedWorktreePath` and the session's own branch for the encoding check); `--summary` mode runs step 1 and drafts the summary content, so the user can review it before anything is sent. Either way, print the plan (and the draft summary, in `--summary` mode) and stop — nothing is created, cloned, fetched, rsynced, registered, or checked.

## The summary document

`--summary` mode's whole point is to hand off without any Claude-specific state, so nothing scripted can write this file — you write it yourself, from what you already know of this conversation, the way `/compact` distills a conversation into a summary rather than reading the transcript back to derive one.

**Filename and placement:** `TELEPORT-<datetime>.md`, with `<datetime>` from `date +%Y%m%d-%H%M%S` (e.g. `TELEPORT-20260806-143205.md`) so it sorts chronologically and is safe on every filesystem. Write it to a scratch file here, push it straight into the worktree root in step 6 — never into this repo's own working tree, since it is not something to leave behind on the source machine.

**Audience:** a fresh Claude Code session with no memory of this conversation, opened by whoever is picking up the work — possibly you on the target machine, possibly a teammate. Write it as a handoff note to that reader, not as a log of what you did. A raw todo-list dump or a truncated tool-call transcript both fail this test; a paragraph that reorients someone who has never seen this conversation passes it.

Structure, adapting to what actually happened rather than forcing every section to be non-empty:

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

## Pulling from `origin` through the forwarded agent

Steps 2 and 3 are the only ones that reach `origin`, and the target should not need its own deploy key or `gh` login for them:

```bash
ssh -A "$DEST" "GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new' git clone '$ORIGIN_URL' '$REPO'"
ssh -A "$DEST" "GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new' git -C '$REPO' fetch origin"
```

`-A` exports `SSH_AUTH_SOCK` on the target so git's own `ssh` authenticates to the forge with the local agent's keys. `GIT_SSH_COMMAND` is needed alongside it because a target that has never talked to the forge has no `known_hosts` entry, and git would then fail on host verification rather than on authentication; `accept-new` trusts an unknown host on first contact but still refuses a *changed* key.

When `agentForwardingOk` is false the target's `sshd` has `AllowAgentForwarding no`, and when `localAgentKeys` is 0 there is nothing to forward. Either way, fall back to the target's own credentials and, if the clone or fetch then fails, name *that* as the cause rather than reporting a bare git error.

Keep `-A` on these two commands only. rsync, worktree creation, registration and verification touch nothing but the target's own filesystem, and anyone with root on the target can use a forwarded agent for as long as the socket is open.

## What travels, and what does not

**Default mode.** `<enc>` is the encoded worktree path; the encoder and its two refusals live in `stage-session.sh`.

| Source | Destination | Why |
|---|---|---|
| `projects/<enc-src>/<sid>.jsonl` | `projects/<enc>/<sid>.jsonl` | The transcript, paths rewritten. |
| `projects/<enc-src>/<sid>/` | `projects/<enc>/<sid>/` | Subagent transcripts, saved tool results, workflows — the transcript references these by relative name, so a session is not one file. |
| `file-history/<sid>/` | same path | `/rewind`. Copied byte-for-byte: these are snapshots of file contents. |
| `tasks/<sid>/.highwatermark` | same path | Task numbering. `.lock` is skipped — a stale lock reads as another process holding the list. |
| `session-env/<sid>/` | same path | Only when non-empty. |
| plan files, from `slug` and every `planFilePath` | `<remoteHome>/.claude/plans/` | Referenced from the transcript by absolute path. |
| this session's `history.jsonl` lines | appended there | Up-arrow recall. Appended, never overwriting the target's own prompts. |
| `projects["<worktree>"].hasTrustDialogAccepted` | `~/.claude.json` | Otherwise the first run in a new directory stops on the trust dialog. |
| modified, staged and untracked files | the worktree | So the target sees the tree this session was reasoning about. |

Not copied, and worth saying so in the report if the user asks: `shell-snapshots/` (this machine's launching shell, not session-keyed — the target makes its own); `sessions/<pid>.json` (a live-process registry); `/tmp/claude-<uid>/…` (regenerated, so background-task output files referenced by old tool results will be absent); `.credentials.json` and the rest of `~/.claude.json`, which carry `machineID`, `userID` and the account's oauth entry.

State these limits rather than papering over them: **which hunks were staged is not preserved** — everything arrives unstaged; a version-skewed target may not load the transcript at all; and MCP servers that need OAuth will re-prompt there.

**`--summary` mode.** Only two things travel, and nothing under `~/.claude` on the target is touched — no transcript, no subagent data, no file history, no task state, no plan file, no `~/.claude.json` edit:

| Source | Destination | Why |
|---|---|---|
| modified, staged and untracked files | the worktree | Same rsync as default mode — the target sees the tree this session was reasoning about. |
| the handoff note you wrote | `<worktree>/TELEPORT-<datetime>.md` | The one thing that stands in for the session itself. |

The limit worth stating here: **which hunks were staged is not preserved**, same as default mode, and the handoff note is only as good as what you put in it — it cannot answer a question the reader has that you did not anticipate.

## Stopping

Stop when `verify` (default mode) or `check-repo` (`--summary` mode) passes, when a step aborts, or when the user redirects. Report using the matching template — the resume instructions are the deliverable.

Default mode:

```
## ssh-teleport: session <short-sid> → <host>

Worktree:  <user>@<host>:<worktree path>  (branch <branch>)
Session:   <sid>  (<n> entries, <size>)
Sent:      transcript, <n> subagent transcripts, <n> tool results,
           <n> file-history entries, <n> plan files, <n> uncommitted files
Left:      <item> — <why>

Resume it there:

  ssh -t <host> 'cd <worktree path> && claude --resume <sid>'

  # or, in two steps:
  ssh <host>
  cd <worktree path>
  claude --resume <sid>

This session is untouched and still resumable here.
```

Name the fallback branch explicitly when step 4 used one, because the user will commit onto it. If `claudeVersion` differed, put that under `Left` as a caveat rather than burying it.

`--summary` mode:

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

## Guardrails

- **Read-only on this machine.** Never modify, move or delete the local session's files. A teleport that fails half way must leave the machine you are sitting at fully resumable — that is the whole safety margin for trying it at all.
- **Never write over a different session on the target.** Re-teleporting the same session id is an update and is fine; abort on `sessionLive`, and never remove a transcript that is not this session's. Does not apply to `--summary` mode, which never touches a transcript at all.
- **Never push to `origin`, commit, stash, or amend.** Step 3 asks first, every time. The working tree travels by rsync precisely so that moving a session does not rewrite history.
- **Never copy credentials or machine identity** — no `.credentials.json`, no wholesale `~/.claude.json`, no `machineID`/`userID`/`oauthAccount`. Agent forwarding is the sanctioned route to `origin` because it lends a key for the life of one command instead of leaving a copy behind.
- **In `--summary` mode, never write anything under `~/.claude` on the target** — no `register`, no `~/.claude.json` edit, no transcript, no plan file. That is the mode's entire purpose; if a step would need to touch `~/.claude` there, it belongs in default mode, not this one.
- **Refuse rather than guess an encoded path.** Exit 4 from `stage-session.sh` is not something to work around by hand; ask for a shorter ASCII worktree path. Does not arise in `--summary` mode, which never encodes a project directory.
- **`--dry-run` writes nothing on the target**, not even the worktree.
- Report honestly: a file that did not transfer is "left", not "sent", and a failed `verify`/`check-repo` is a failure even though every earlier step succeeded. The user is about to close this session and trust the other machine (or hand it to someone else) on the strength of this report.
