# When a teleported session does not come back

Work down this list from the symptom the user actually reports. Every error string here is one Claude Code, git or ssh really prints.

## The session does not resume

**`No conversation found with session ID: <id>`** — the transcript is not in the project directory for the resume directory's `realpath`. Usual causes, in order of likelihood:

1. Resuming from a different directory than the worktree. The fix is `cd <worktree path>` first; session-id lookup is scoped to the current project directory and its worktrees.
2. The worktree path used for staging was not the target's `realpath`. Re-run `remote-setup.sh verify --path <worktree> --session-id <sid>` and compare its `encodedDir` against what is actually on disk under `~/.claude/projects/`.
3. The path contains a symlink that resolves differently than expected — `cd <worktree> && pwd -P` on the target settles it.

**`This conversation is from a different directory.`**, usually followed by a `cd … && claude --resume …` hint — the transcript was found by the full-directory-scan fallback but its recorded `cwd` disagrees with where you are. That means the rewrite did not take: check `jq -rs 'map(select(.cwd)) | .[0].cwd' <transcript>` on the target against the worktree path.

**`No conversations found to resume`** from the picker, even though `--resume <id>` works — the transcript is in the wrong encoded directory and only the full-scan fallback is finding it. Deterministic lookup and the picker both need the correct directory; restage with the right `--target-cwd`.

**The session resumes but the transcript is empty or truncated.** Check the target's `claude --version` against the source's. The JSONL entry format is internal and changes between releases, and a newer reader will not necessarily accept an older writer's entries or the reverse. There is no fix from this side beyond matching versions.

**`Session ID is invalid or expired`** — a catch-all that mostly means the same thing as the first case. Do not read it as an expiry.

## Trust and first launch

**Claude Code stops on the trust dialog in the worktree** — `register` did not run, or it ran against a path that is not the one being launched from. Check `jq '.projects["<worktree>"]' ~/.claude.json` on the target. Accepting the dialog by hand is equally fine; the merge only saves a keystroke.

Note that non-interactive runs (`claude -p`) skip the trust check entirely, so a `-p` smoke test passing does not prove the interactive path is trusted.

## Reaching `origin` from the target

**`Permission denied (publickey).`** during the clone or fetch — the target has no key for the forge and the forwarded agent was not usable. Two distinct causes worth separating before reporting:

- `localAgentKeys: 0` from the probe: there is no agent here, or it holds no keys. `ssh-add -l` should list at least one; `ssh-add ~/.ssh/<key>` fixes it. A passphrase-protected key file that was never added to an agent cannot be forwarded.
- `agentForwardingOk: false`: the target's `sshd` has `AllowAgentForwarding no`. Nothing on this side changes that — either the target gets its own credentials for `origin`, or an admin enables forwarding.

**`Host key verification failed.`** — the target has never talked to the forge and `GIT_SSH_COMMAND` was not carried into the remote command. Both `origin` commands need it:

```bash
ssh -A "$DEST" "GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new' git -C '$REPO' fetch origin"
```

Do not reach for `StrictHostKeyChecking=no`; `accept-new` trusts an unknown host on first contact and still refuses a key that has *changed*, which is the check worth keeping.

**`error: commit <sha> is not present in <repo> — fetch it first`** (exit 5 from `remote-setup.sh worktree`) — the fetch did not bring the session's commit, because it was never pushed. That is the one point where the skill asks permission to push, and declining is a legitimate answer: teleport a session whose HEAD is published instead.

## The worktree

**`fatal: '<branch>' is already checked out at …`** should never surface: `worktree` creates a new branch at the commit and falls back to `<branch>.teleport-<suffix>` when the name is taken. If you see it, `--suffix` was reused across two teleports of different sessions.

**`error: branch '<name>' already exists here and is not at <commit>`** — a previous teleport left that branch behind at a different commit. Delete it on the target (`git -C <repo> branch -D <name>`) once you have confirmed nothing depends on it, or pick a different worktree path.

**`error: '<path>' already exists and is not a git worktree`** — something unrelated occupies the path. Pick another; the skill will not clear a directory it did not create.

## The working tree does not match

**Everything shows as unstaged on the target.** Expected, and stated in the report: the files travel by content, so the index/worktree split does not survive. Re-stage there with `git add -p` if it matters.

**A file is missing on the target.** It was ignored here: the file list comes from `git ls-files --others --exclude-standard`, which honours `.gitignore`. Ignored build output is deliberately left behind. If the session genuinely depended on an ignored file, copy it across by hand and say so.

**A file deleted here still exists there.** The deletion pass (`git ls-files --deleted`) did not run or hit a path with a newline in it. Check with `git -C <worktree> status --porcelain` on the target against the same command here.

## `/rewind` after a move

In-repo history works: the backup filenames hash the *relative* tracking path, which does not change. Out-of-repo entries — most visibly the plan file under `~/.claude/plans/` — were keyed by absolute path, and although the transcript's key is rewritten, the backup filename still hashes the old one, so those specific pre-move versions are not reachable. Edits made after the teleport rewind normally.

## Diagnosing from the target

`remote-setup.sh verify` reports each check separately, so run it before guessing:

```bash
ssh <host> bash -s -- verify --path <worktree> --session-id <sid> < scripts/remote-setup.sh
```

`worktree: false` is a git problem, `transcriptPresent: false` an encoding or rsync problem, `cwdMatches: false` a rewrite problem, `trusted: false` a `register` problem. `resumable: false` means the transcript has no user or assistant entry at all, which points at a truncated transfer.
