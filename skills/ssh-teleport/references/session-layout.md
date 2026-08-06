# Where a Claude Code session lives on disk

Read this when a teleport lands somewhere unexpected, or when something in the session did not survive the move and you need to know whether it ever could have.

This entire document is about **default-mode** teleports. A `--summary` teleport never reads or writes anything described here — it copies the repo and a written handoff note, nothing under `~/.claude`. If you are troubleshooting a `--summary` run, this is the wrong file; there is no session-layout problem to have.

Everything below was verified against Claude Code **2.1.222** on Linux. Anthropic's own documentation is explicit that this is not a stable contract:

> The entry format is internal to Claude Code and changes between versions, so scripts that parse these files directly can break on any release.

That is why `ssh-teleport` warns on a version-skewed target instead of assuming a transcript is portable.

## The project directory name

Transcripts live at `~/.claude/projects/<encoded>/<session-id>.jsonl`, where `<encoded>` is derived from the session's working directory:

1. The key is `realpath(cwd)` — symlinks are resolved first. This is why `remote-setup.sh worktree` returns the target's `realpath` and `stage-session.sh` is given *that*, not the path the user typed.
2. Every character that is not `[a-zA-Z0-9]` becomes `-`. Not just `/`: also `_`, `.`, `~` and spaces. Case is preserved and runs of `-` are not collapsed.
3. If the result exceeds 200 characters it is truncated to 200 and given a `-<hash>` suffix, where the hash is an internal base-36 string hash.

`/home/ashir/Documents/jetson-flash-advantech-MIC713/Linux_for_Tegra` therefore becomes `-home-ashir-Documents-jetson-flash-advantech-MIC713-Linux-for-Tegra`.

`stage-session.sh` refuses two cases rather than guessing:

- **Non-ASCII paths.** Claude Code substitutes per UTF-16 code unit; `sed` substitutes per byte. `/home/bob/프로젝트/app` encodes to `-home-bob----app` in Claude Code and `-home-bob------app` through `sed`, so the transcript would land in a directory nothing looks in.
- **Encodings over 200 characters**, where the suffix hash cannot be reproduced in bash.

The encoding is **lossy and not invertible** — `~/code/foo` and `~/code-foo` produce the same name. Never decode a directory name back to a path; read `cwd` out of the transcript instead, which is what `stage-session.sh` does to find the session it was asked for.

## How `--resume <id>` finds a transcript

In order: a link-scan hint, then the project directories for `realpath(cwd)`, then the computed path, then sibling git-worktree project directories, then a full scan of `~/.claude/projects/*/` accepted only if exactly one directory holds that id. A file counts as resumable only if it contains a line with `"type":"user"` or `"type":"assistant"` — `stage-session.sh` asserts that after rewriting, and `remote-setup.sh verify` checks it again on the target.

The full-scan fallback means a transcript in a *slightly* wrong directory often still resumes by id. Do not rely on it: `--continue` and the `/resume` picker are both scoped to the current directory's project directory, so only the correctly encoded path behaves properly.

## What is keyed by what

| Path | Keyed by | Travels? |
|---|---|---|
| `projects/<enc>/<sid>.jsonl` | project path + session id | yes, rewritten |
| `projects/<enc>/<sid>/subagents/`, `tool-results/`, `workflows/` | project path + session id | yes, rewritten |
| `projects/<enc>/memory/` | project path | no — project-scoped, not session-scoped |
| `file-history/<sid>/<16-hex>@v<N>` | session id; the hash is over the *tracking path* | yes, copied verbatim |
| `tasks/<sid>/` | session id | `.highwatermark` only |
| `session-env/<sid>/` | session id | yes, when non-empty |
| `plans/<slug>.md` | slug, referenced by absolute path | yes |
| `history.jsonl` | global, one line per prompt, carries `project` and `sessionId` | matching lines appended |
| `shell-snapshots/` | neither session nor project | no |
| `sessions/<pid>.json` | live process | no |
| `~/.claude.json` `projects["<abs path>"]` | raw absolute path, not the encoded name | one key merged |

`claude project purge --dry-run <path>` prints the CLI's own view of this list, and is the quickest way to check it against a newer version.

### Why file history survives the move

`trackedFileBackups` keys are **relative to `cwd` when the file is under `cwd`**, absolute otherwise. The `<16-hex>` backup filenames are hashes of those tracking paths, so for in-repo files they stay valid at the new location and `/rewind` keeps working. Only the absolute keys and the `realParentDir` values need rewriting, which the same substitution pass handles. The backup files themselves are copied byte-for-byte — they are snapshots of file *contents*, and substituting inside them would corrupt what `/rewind` restores.

## The fields that carry machine state

Rewritten by `stage-session.sh`: `cwd`, `gitBranch`, `message.content[].input.file_path`, `…input.command`, `…input.planFilePath`, `toolUseResult.filePath`, `toolUseResult.file.filePath`, `toolUseResult.stdout`/`stderr`, tool-result bodies, `attachment.attachment.planFilePath`, `file-history-delta.backup.realParentDir`, and `file-history-snapshot.snapshot.trackedFileBackups` keys. It reaches all of them by walking every string value *and* every object key, rather than enumerating fields that change between versions.

Left alone deliberately: `sessionId`, `session_id`, `uuid`, `parentUuid`, `promptId`, `requestId` (so `--resume <id>` still resolves and the message chain stays intact) and `version` (a historical per-entry stamp; rewriting it would misreport which version wrote each entry).

There is no `hostname`, `machineID`, `platform` or `originalCwd` anywhere in a transcript, so there is nothing else machine-specific left to fix.

## Trust

`~/.claude.json` holds `projects["<absolute path>"]`, keyed by the raw path. A path with no entry is untrusted, and an interactive `claude` run there stops on the trust dialog. `register` merges `hasTrustDialogAccepted: true` for the worktree and nothing else — that file also holds `machineID`, `userID` and `oauthAccount`, and Claude Code rewrites it frequently, so it is merged atomically in place and never replaced.

One thing worth knowing but out of scope here: `cleanupPeriodDays` defaults to 30, and the sweep is by file age. Freshly rsynced transcripts have current timestamps, so a teleported session is not at risk; a restored *backup* of an old one would be.
