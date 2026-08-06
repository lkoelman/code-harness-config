---
name: ssh-teleport
description: Copy the current Claude Code session to another machine over ssh/rsync and resume it there in a git worktree. Use when the user wants to move, hand off, or continue this session on a different host — "teleport this session to the gpu box", "continue this on my other machine", "send this session to <host>" — or asks for the ssh and claude commands to pick this conversation up elsewhere.
harnesses: [claude]
argument-hint: --host <hostname> [--user <username>] [--repo-path <path>] [--worktree-path <path>] [--dry-run]
---

## When to use me

Use this skill to move **this** session to another machine: transcript, subagent transcripts, saved tool results, plan file, task numbering, file history, and the working tree it was reasoning about, landing in a fresh git worktree on the target so that machine's own checkout is left alone. It ends by printing the `ssh` and `claude` commands that resume the conversation there.

Not for moving between directories on the *same* machine — Claude Code does that natively (`/cd` relocates the session's project storage, `EnterWorktree`/`ExitWorktree` move it into and out of a worktree, and `Ctrl+W` widens the `/resume` picker across a repo's worktrees). Not for syncing all of `~/.claude` either; that is a dotfiles job, and `./scripts/install.sh` is how this repo's skills and agents reach a machine.

## Parameters

| Flag | Default | Meaning |
|---|---|---|
| `--host <hostname>` | **none — required** | Target host: an `~/.ssh/config` alias or a hostname. |
| `--user <username>` | from `ssh -G <host>` | Login user. Required when the host has no `Host` block in `~/.ssh/config`. |
| `--repo-path <path>` | probed on the target | Existing clone of this repo there. |
| `--worktree-path <path>` | `<parent of repo>/worktrees-<repo>/<branch>` | Where the worktree is created. |
| `--dry-run` | off | Probe and stage, print the plan, write nothing on the target. |

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
| `scripts/probe-target.sh --host H [--user U] [--repo-path P]` | here, one `ssh -A` round trip | Every target fact as one JSON document. Exit 2 unreachable, 3 missing `claude`/`jq`/`rsync` there. |
| `scripts/stage-session.sh --session-id … --target-cwd … --target-home … --target-branch … --out DIR` | here | Builds a mirror of the target's `~/.claude` with every path rewritten; prints a manifest. Exit 4 if the target path cannot be encoded. |
| `scripts/remote-setup.sh <worktree\|register\|verify> …` | **on the target**, streamed in | `ssh <dest> bash -s -- <cmd> … < "$SKILL_DIR/scripts/remote-setup.sh"`. Exit 5 unknown commit, 6 would not resume. |

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

Abort if this is not a git repository — the worktree is the whole point. Then post a one-paragraph opening summary: host and login user, target repo path, worktree path and branch, session id, transcript size, and how many uncommitted files will travel. That paragraph is the user's last chance to redirect before anything is written on the target.

1. **Probe.** `probe-target.sh --host <host> [--user <u>] [--repo-path <p>]`. Stop on exit 2 or 3. Stop if `sessionLive` is true — that session id is already open on the target, and writing under a live session corrupts it. Warn but continue if `claudeVersion` differs from local in anything but the patch number: the transcript format is internal to Claude Code and changes between versions. If `localAgentKeys` is 0 or `agentForwardingOk` is false, say so now, because steps 2 and 3 are the ones that will feel it.

2. **Settle the repo.** With `repoPath` non-empty and `originMatches` true, use it. Otherwise ask for a path and clone through the forwarded agent (below). A clone can take a while on a large repo; say what you are doing before you start it.

3. **Make the commit reachable.** If `headPresent` is false, fetch through the forwarded agent and re-probe. Still missing means the commits exist only here: **ask** before pushing anything to `origin`, and abort if the user says no. Never push as a silent side effect of a teleport.

4. **Create the worktree.**

   ```bash
   ssh "$DEST" bash -s -- worktree --repo "$REPO" --path "$WORKTREE" \
       --branch "$BRANCH" --commit "$COMMIT" --suffix "${SID%%-*}" \
       < "$SKILL_DIR/scripts/remote-setup.sh"
   ```

   It uses the session's own branch name when that name is free on the target and `<branch>.teleport-<suffix>` when it is not, either way checked out at exactly `$COMMIT`. **Take `path` and `branch` from its output, not from what you asked for** — `path` is the target's `realpath`, which is what the project-directory encoding is computed from, and `branch` is what the target is really on. Exit 5 means step 3 did not actually land the commit.

5. **Stage.** `stage-session.sh --session-id "$SID" --target-cwd <path from step 4> --target-home <remoteHome> --target-branch <branch from step 4> --out "$SCRATCH/stage"`. Exit 4 means the worktree path cannot be encoded the way Claude Code would encode it (non-ASCII, or over 200 characters once encoded) — ask for a shorter ASCII path and redo step 4 rather than pressing on, because the transcript would land where `--resume` cannot deterministically find it. Read the manifest and keep the counts for the closing report.

6. **Push.** Two rsyncs and nothing else. First the staged session, which already mirrors the target's `~/.claude` layout, so there is no path arithmetic left to get wrong:

   ```bash
   rsync -az "$SCRATCH/stage/" "$DEST":
   ```

   Then the working tree the session was looking at — modified, staged and untracked files that still exist, with `.git` never in the set:

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

7. **Register and verify.**

   ```bash
   ssh "$DEST" bash -s -- register --path "$WORKTREE" --session-id "$SID" \
       < "$SKILL_DIR/scripts/remote-setup.sh"
   ssh "$DEST" bash -s -- verify --path "$WORKTREE" --session-id "$SID" \
       < "$SKILL_DIR/scripts/remote-setup.sh"
   ```

   `register` merges one project key into `~/.claude.json` so the first `claude` run there does not stop on the trust dialog, and appends this session's prompt-history lines. `verify` exits 6 if the session would not resume; when it does, report which of `worktree`/`transcriptPresent`/`resumable`/`cwdMatches` came back false instead of printing resume instructions that will not work.

With `--dry-run`, do steps 1 and 5 only — step 5 needs a target path, so use `suggestedWorktreePath` and the session's own branch for the encoding check — then print the plan and the manifest and stop. Nothing is created, cloned, fetched, rsynced or registered.

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

`<enc>` is the encoded worktree path; the encoder and its two refusals live in `stage-session.sh`.

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

## Stopping

Stop when `verify` passes, when a step aborts, or when the user redirects. Report using this template — the resume commands are the deliverable:

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

## Guardrails

- **Read-only on this machine.** Never modify, move or delete the local session's files. A teleport that fails half way must leave the machine you are sitting at fully resumable — that is the whole safety margin for trying it at all.
- **Never write over a different session on the target.** Re-teleporting the same session id is an update and is fine; abort on `sessionLive`, and never remove a transcript that is not this session's.
- **Never push to `origin`, commit, stash, or amend.** Step 3 asks first, every time. The working tree travels by rsync precisely so that moving a session does not rewrite history.
- **Never copy credentials or machine identity** — no `.credentials.json`, no wholesale `~/.claude.json`, no `machineID`/`userID`/`oauthAccount`. Agent forwarding is the sanctioned route to `origin` because it lends a key for the life of one command instead of leaving a copy behind.
- **Refuse rather than guess an encoded path.** Exit 4 from `stage-session.sh` is not something to work around by hand; ask for a shorter ASCII worktree path.
- **`--dry-run` writes nothing on the target**, not even the worktree.
- Report honestly: a file that did not transfer is "left", not "sent", and a failed `verify` is a failure even though every earlier step succeeded. The user is about to close this session and trust the other machine.
