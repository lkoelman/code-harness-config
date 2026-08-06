---
name: ssh-teleport
harnesses: [claude]
argument-hint: --host <hostname> [--user <username>] [--repo-path <path>] [--worktree-path <path>] [--summary] [--dry-run]
---

## When to use me

Use this skill to move **this** session to another machine: transcript, subagent transcripts, saved tool results, plan file, task numbering, file history, and the working tree it was reasoning about, landing in a fresh git worktree on the target so that machine's own checkout is left alone. It ends by printing the `ssh` and `claude` commands that resume the conversation there.

Pass `--summary` when the target should get the code and a written handoff, and nothing Claude-specific — handing off to a teammate, a target that will start its own fresh Claude Code session, or any case where copying the transcript is not wanted. That mode has its own steps 5 to 7, its own report, and its own failure modes, all in `references/summary-mode.md`; read that file during the preflight when `--summary` is passed.

Not for moving between directories on the *same* machine — Claude Code does that natively (`/cd` relocates the session's project storage, `EnterWorktree`/`ExitWorktree` move it into and out of a worktree, and `Ctrl+W` widens the `/resume` picker across a repo's worktrees). Not for syncing all of `~/.claude` either; that is a dotfiles job, and `./scripts/install.sh` is how this repo's skills and agents reach a machine.

## Parameters

| Flag | Default | Meaning |
|---|---|---|
| `--host <hostname>` | **none — required** | Target host: an `~/.ssh/config` alias or a hostname. |
| `--user <username>` | from `ssh -G <host>` | Login user. Required when the host has no `Host` block in `~/.ssh/config`. |
| `--repo-path <path>` | probed on the target | Existing clone of this repo there. |
| `--worktree-path <path>` | `<parent of repo>/worktrees-<repo>/<branch>` | Where the worktree is created. |
| `--summary` | off | Send only the repo (dirty files) plus a generated handoff note. Nothing under `~/.claude` on the target is touched at all. See `references/summary-mode.md`. |
| `--dry-run` | off | Probe and stage (or draft the summary), print the plan, write nothing on the target. |

There is no flag for agent forwarding: the two commands that reach `origin` always use `ssh -A`, and nothing else does.

Fill in what is missing rather than guessing:

- **`--host`** absent → ask. Nothing else can be derived without it.
- **`--user`** absent → read `userFromConfig` from the probe. When it is false the user it resolved is just the local `$USER` echoed back by `ssh -G`, which is not evidence — ask.
- **`--repo-path`** absent → use `repoPath` from the probe. When it comes back empty the target has no clone of this repo in any of the usual places, so ask where to put one and clone it (step 2).
- **`--worktree-path`** absent → use `suggestedWorktreePath` from the probe, and name it in the opening summary so the user can redirect it before anything is written.

## Bundled scripts

| Script | Runs | Purpose |
|---|---|---|
| `scripts/probe-target.sh --host H [--user U] [--repo-path P] [--require LIST]` | here, one `ssh -A` round trip | Every target fact as one JSON document. Exit 2 unreachable, 3 missing one of `--require`'s dependencies (default `jq,rsync,git,claude`). |
| `scripts/stage-session.sh --session-id … --target-cwd … --target-home … --target-branch … --out DIR` | here | **Default mode only.** Builds a mirror of the target's `~/.claude` with every path rewritten; prints a manifest. Exit 4 if the target path cannot be encoded. |
| `scripts/remote-setup.sh <worktree\|register\|verify\|check-repo> …` | **on the target**, streamed in | `ssh <dest> bash -s -- <cmd> … < "$SKILL_DIR/scripts/remote-setup.sh"`. Exit 5 unknown commit, 6 default-mode session would not resume, 7 `--summary` mode's `check-repo` found the worktree or the summary file wrong. |

`references/summary-mode.md` is required reading when `--summary` is passed, and irrelevant otherwise. The other two are for after the fact: `references/session-layout.md` explains where session state lives and why each piece travels, and `references/troubleshooting.md` maps the failure modes to their actual error strings. Read those two when something does not land, not up front.

Bind these once, before step 1, so every snippet below is runnable as written:

```bash
SKILL_DIR="$HOME/.claude/skills/ssh-teleport"
SCRATCH="$(mktemp -d)"                          # staging and the draft handoff note
SID="$CLAUDE_CODE_SESSION_ID"                   # never a session id guessed from file mtimes
COMMIT="$(git rev-parse HEAD)"
ORIGIN_URL="$(git remote get-url origin)"
```

The rest come from output rather than from here, and taking them from anywhere else is the most common way a teleport lands wrong:

- From the probe (step 1): `DEST` = `dest` (`user@host`, or bare `host` when `~/.ssh/config` supplies the user), `REMOTE_HOME` = `remoteHome`, `REPO` = `repoPath` or the path the user gives when it is empty.
- What you *ask* step 4 for: `WORKTREE_REQUEST` = `--worktree-path` or the probe's `suggestedWorktreePath`, `BRANCH_REQUEST` = `git branch --show-current`.
- What step 4 *answers*: `WORKTREE` = its `path`, `BRANCH` = its `branch`. These are the target's `realpath` and the branch it is really on, and they are what every later step uses.

## The teleport

Steps 1 to 4, and the working-tree rsync at the top of step 6, are the same in both modes. From step 5 on, `--summary` mode follows `references/summary-mode.md` instead of what is written here.

**Run the preflight first**, read-only, and abort on any failure:

```bash
echo "$SID"                         # the session being moved
git rev-parse --show-toplevel HEAD
git branch --show-current
git remote get-url origin
claude --version
ssh-add -l                          # the keys the target will borrow
test "$(pwd -P)" = "$(cd "$(git rev-parse --show-toplevel)" && pwd -P)"
```

Abort if this is not a git repository — the worktree is the whole point. Abort too if that last check fails, and say why: the session is running in a subdirectory of the repo, and both the file list in step 6 and the encoded project directory in step 5 assume the session's cwd *is* the repo root. Teleporting from a subdirectory would silently drop dirty files outside it and rewrite the transcript's `cwd` to the wrong directory, so the honest answer is to start a session at the repo root and teleport that one instead.

**Then post a one-paragraph opening summary** covering: host, login user, and — when the host is an `~/.ssh/config` alias — the `hostname` and `port` it resolved to; the target repo path; the worktree path and the branch it will land on, naming `<branch>.teleport-<suffix>` when the probe's `branchExists` is true, because that is the branch the user will end up committing onto; the mode; the session id; the transcript size (default mode) or that there is nothing to summarize yet (`--summary` mode); and how many uncommitted files will travel. That paragraph is the user's last chance to redirect before anything is written on the target.

1. **Probe the target.** Run `probe-target.sh --host <host> [--user <u>] [--repo-path <p>]`. In `--summary` mode add `--require rsync,jq,git`: that mode is the only one that does not need `claude` on the target, but `remote-setup.sh` uses `jq` and `git` in every mode. Stop on exit 2 or 3.

   Then, default mode only: stop if `sessionLive` is true — that session id is already open on the target, and writing under a live session corrupts it. Warn but continue if `claudeVersion` differs from local in anything but the patch number, since the transcript format is internal to Claude Code and changes between versions.

   Either mode: if `localAgentKeys` is 0 or `agentForwardingOk` is false, say so now, because steps 2 and 3 are the ones that will feel it.

2. **Settle the repo.** Use `repoPath` when it is non-empty — the probe only reports a path whose `origin` matches this repo's, so a non-empty value is already confirmation (`originMatches` mirrors it). Otherwise ask for a path and clone through the forwarded agent (below). Say what you are doing before you start a clone; on a large repo it takes a while.

3. **Make the commit reachable.** If `headPresent` is false, fetch through the forwarded agent and re-probe. Still missing means the commits exist only here: **ask** before pushing anything to `origin`, and abort if the user says no. Never push as a silent side effect of a teleport.

4. **Create the worktree.**

   ```bash
   ssh "$DEST" bash -s -- worktree --repo "$REPO" --path "$WORKTREE_REQUEST" \
       --branch "$BRANCH_REQUEST" --commit "$COMMIT" --suffix "${SID%%-*}" \
       < "$SKILL_DIR/scripts/remote-setup.sh"
   ```

   It uses the session's own branch name when that name is free on the target and `<branch>.teleport-<suffix>` when it is not, either way checked out at exactly `$COMMIT`. **Set `WORKTREE` and `BRANCH` from its output, not from what you asked for** — `path` is the target's `realpath`, and default mode needs it exactly right for the project-directory encoding. Exit 5 means step 3 did not actually land the commit.

5. **Stage the session** (default mode):

   ```bash
   stage-session.sh --session-id "$SID" --target-cwd "$WORKTREE" \
       --target-home "$REMOTE_HOME" --target-branch "$BRANCH" --out "$SCRATCH/stage"
   ```

   Exit 4 means the worktree path cannot be encoded the way Claude Code would encode it (non-ASCII, or over 200 characters once encoded). Ask for a shorter ASCII path and redo step 4 rather than pressing on, because the transcript would land where `--resume` cannot deterministically find it. Read the manifest and keep the counts for the closing report.

6. **Push the working tree** — modified, staged and untracked files that still exist, with `.git` never in the set:

   ```bash
   { git ls-files -z --modified --others --exclude-standard
     git diff --cached --name-only -z; } | sort -zu \
     | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done \
     | rsync -az --files-from=- --from0 ./ "$DEST:$WORKTREE/"
   ```

   Remove the files deleted here but present in `HEAD`, or the worktree will disagree with what the session believes. Keep the list NUL-separated the whole way, so a path with a newline in it is handled like any other:

   ```bash
   git ls-files -z --deleted | ssh "$DEST" "cd '$WORKTREE' && xargs -0 -r rm -f --"
   ```

   Then push the staged session, which already mirrors the target's `~/.claude` layout, so there is no path arithmetic left to get wrong:

   ```bash
   rsync -az "$SCRATCH/stage/" "$DEST":
   ```

7. **Register and verify** (default mode):

   ```bash
   ssh "$DEST" bash -s -- register --path "$WORKTREE" --session-id "$SID" \
       < "$SKILL_DIR/scripts/remote-setup.sh"
   ssh "$DEST" bash -s -- verify --path "$WORKTREE" --session-id "$SID" \
       < "$SKILL_DIR/scripts/remote-setup.sh"
   ```

   `register` merges one project key into `~/.claude.json` so the first `claude` run there does not stop on the trust dialog, and appends this session's prompt-history lines. `verify` exits 6 if the session would not resume; when it does, report which of `worktree`/`transcriptPresent`/`resumable`/`cwdMatches` came back false instead of printing resume instructions that will not work.

Remove `$SCRATCH` once the report is out; it holds a rewritten copy of the transcript.

With `--dry-run`, run the preflight and step 1, then — in default mode — step 5 against `suggestedWorktreePath` and the session's own branch, purely for the encoding check. Print the plan and stop: nothing is created, cloned, fetched, rsynced, registered or checked. Say in the plan whether a clone, a fetch, or a **push to `origin`** would be needed, since that is the part of a teleport the user most wants to approve in advance.

## Example

**Input:** "teleport this session to the gpu box", where `gpu-box` is an `~/.ssh/config` alias and nothing else was given.

Derived: `--host gpu-box`, default mode. `--user`, `--repo-path` and `--worktree-path` all come from the probe.

**Opening summary, posted before anything is written on the target:**

> Teleporting session `ba4c5bed` to `lucas@gpu-box` (`10.0.0.9:22`). Target clone `/home/lucas/code/code-harness-config` already has this commit, so no fetch is needed. The worktree goes to `/home/lucas/code/worktrees-code-harness-config/main` — but `main` already exists there, so it will land on `main.teleport-ba4c5bed`, which is the branch you would be committing onto. Transcript is 412 entries / 1.8 MB, and 3 uncommitted files travel with it. Say now if the worktree should go somewhere else.

**Output:** the default-mode template under "Stopping", whose `ssh -t gpu-box 'cd /home/lucas/code/worktrees-code-harness-config/main && claude --resume ba4c5bed-…'` line is the actual deliverable.

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

Default mode; `references/summary-mode.md` has the equivalent for `--summary`. `<enc>` is the encoded worktree path; the encoder and its two refusals live in `stage-session.sh`.

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

Stop when `verify` passes, when a step aborts, or when the user redirects. Report with this template — the resume instructions are the deliverable. (`--summary` mode has its own; see `references/summary-mode.md`.)

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
- **Never write over a different session on the target.** Re-teleporting the same session id is an update and is fine; abort on `sessionLive`, and never remove a transcript that is not this session's. Does not apply to `--summary` mode, which never touches a transcript at all.
- **Never push to `origin`, commit, stash, or amend.** Step 3 asks first, every time. The working tree travels by rsync precisely so that moving a session does not rewrite history.
- **Never copy credentials or machine identity** — no `.credentials.json`, no wholesale `~/.claude.json`, no `machineID`/`userID`/`oauthAccount`. Agent forwarding is the sanctioned route to `origin` because it lends a key for the life of one command instead of leaving a copy behind.
- **In `--summary` mode, never write anything under `~/.claude` on the target** — no `register`, no `~/.claude.json` edit, no transcript, no plan file. That is the mode's entire purpose; if a step would need to touch `~/.claude` there, it belongs in default mode, not this one.
- **Refuse rather than guess an encoded path.** Exit 4 from `stage-session.sh` is not something to work around by hand; ask for a shorter ASCII worktree path.
- **`--dry-run` writes nothing on the target**, not even the worktree.
- Report honestly: a file that did not transfer is "left", not "sent", and a failed `verify`/`check-repo` is a failure even though every earlier step succeeded. The user is about to close this session and trust the other machine (or hand it to someone else) on the strength of this report.
