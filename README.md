# Code Harness Config

**Write a skill once, run it in every coding agent you use.** Claude Code, Codex CLI, Gemini CLI, OpenCode and pi-agent each want their own config directory and their own frontmatter dialect — so the same prompt ends up copy-pasted five times and drifts in four of them. This repo keeps one canonical copy of each skill and agent, splices in whatever per-harness metadata is needed at build time, and symlinks the result into place. Edit the source, re-run `install.sh`, and every harness is up to date.

## Skills

| Skill | What it does |
|---|---|
| [`autofix-pr-local`](skills/autofix-pr-local/SKILL.md) | Shepherds an open PR to green from your machine: loops over failing CI checks, reviewer and bot comments, and base-branch conflicts, fixing the highest-priority signal and committing one fix per issue. |
| [`grill-for-pr`](skills/grill-for-pr/SKILL.md) | Interviews you for the context a diff can't show, then writes a PR title and description engineered for reviewer buy-in — honest, persuasive, and short enough to actually get read. |
| [`github-cli`](skills/github-cli/SKILL.md) | House rules for driving issues, pull requests and review threads through `gh` instead of ad hoc API calls or web fetches. |
| [`remote-git-examples`](skills/remote-git-examples/SKILL.md) | Inspect code behind a GitHub (or any remote git) URL by shallow-cloning it to a temp dir rather than scraping the web UI. |
| [`ssh-teleport`](skills/ssh-teleport/SKILL.md) | Moves the current Claude Code session to another machine — transcript, tool results, plan, file history and working tree — landing in a fresh worktree there. `--summary` sends the code plus a written handoff instead, for a teammate or a fresh session. |
| [`document-architecture`](skills/document-architecture/SKILL.md) | Generates an `ARCHITECTURE.md` for an existing codebase, written as an onboarding entry point for both new developers and coding agents. |
| [`handoff-doc`](skills/handoff-doc/SKILL.md) | Write handoff document so you can /clear or /compact the context window and the next agent can continue the session. |

Agent definitions live alongside them in [`agents/`](agents/): `autoplan`, `github-orchestrator-agent`, `github-worker-agent`, `planner-codex`, `plan-writer` and `search-grounding`.

## Layout

```
skills/<name>/SKILL.md               # one skill, shared across every harness
agents/<name>/AGENT.md               # one agent definition, shared across every harness
harnesses/<harness>.conf             # where each harness's skills/agents/settings live
harnesses/pi-agent/settings.json     # pi-agent's settings.json, symlinked in on install
harnesses/claude/CLAUDE.md           # Claude Code's global CLAUDE.md, symlinked in on install
scripts/install-prerequisites.sh     # installs gh, jq and the gh extensions the skills need
scripts/build.sh                     # splices frontmatter, writes build/<harness>/...
scripts/install.sh                   # builds, then symlinks into each harness's config dir
scripts/uninstall.sh                 # removes symlinks this repo created
scripts/test.sh                      # tests for the scripts above and for bundled skill scripts
build/                               # generated output (gitignored)
```

A `SKILL.md` or `AGENT.md` holds the harness-neutral frontmatter (`name`/`description`) and the body. Where a harness needs extra frontmatter it can't share with the others — tool permissions, `mode:`, `model:`, pi-agent's `thinking:`/`systemPromptMode:`, etc. — that goes in a sidecar `header-<harness>.yaml` next to it. At build time the two are spliced together; harnesses that need nothing extra just get the common frontmatter as-is.

## Prerequisites

- [GitHub CLI](https://github.com/cli/cli/blob/trunk/docs/install_linux.md) (`gh`) — used by the `github-cli` and `grill-for-pr` skills and the GitHub-driven agents.
- The [`gh-pr-review`](https://github.com/agynio/gh-pr-review) extension, for inline PR review comment workflows: `gh extension install agynio/gh-pr-review`.
- The [`gh-webhook`](https://github.com/cli/gh-webhook) extension, only if you want push-style GitHub event forwarding instead of polling: `gh extension install cli/gh-webhook`. Note it needs admin rights on the repo to register the webhook, plus a local HTTP receiver.
- `jq` — used by the `github-cli`, `autofix-pr-local`, `grill-for-pr` and `ssh-teleport` skills to read structured JSON.
- `rsync` — used by the `ssh-teleport` skill to move session data between machines. **On the target** it needs `rsync`, `jq` and `git` in every mode, plus `claude` at a version matching the source for anything but a `--summary` handoff; and, so the target can pull from `origin` without credentials of its own, a local `ssh-agent` holding a usable key (`ssh-add -l`) plus `AllowAgentForwarding` enabled on the target.

To install all of the above:

```bash
./scripts/install-prerequisites.sh              # add --dry-run to see what it would do
./scripts/install-prerequisites.sh --skip-webhook
```

Each step checks first, so re-running is a no-op once everything is present. Installing `gh` or `jq` needs `sudo`; on an apt system with no `gh` candidate it adds the official `cli.github.com` repo first. Installing the extensions needs `gh auth login` to have been run.

No other tooling is required for the build itself — `build.sh`/`install.sh` are plain bash with no dependencies (no GNU Stow, no Node).

## Installing

```bash
./scripts/install.sh --all
# or install/update just one harness:
./scripts/install.sh opencode
```

This builds `build/<harness>/...` from `skills/` and `agents/`, then symlinks each skill and agent individually into the harness's config directory — unrelated files already there are left alone. Re-running is safe (idempotent) and picks up any changes after a `git pull`.

| Harness | Skills | Agents | Notes |
|---|---|---|---|
| Claude Code | `~/.claude/skills/<name>` | `~/.claude/agents/<name>.md` | No agent headers are defined yet, so no agents install here. Also symlinks `harnesses/claude/CLAUDE.md` to `~/.claude/CLAUDE.md` (the global instructions applied to every session). |
| Codex CLI | `~/.codex/skills/<name>` | — | Codex doesn't support markdown subagent definitions. |
| Gemini CLI | `~/.gemini/skills/<name>` | `~/.gemini/agents/<name>.md` | Run `/skills reload` after installing/updating. |
| OpenCode | `~/.config/opencode/skills/<name>` | `~/.config/opencode/agents/<name>.md` | Native path, not `~/.opencode/`. |
| pi-agent | `~/.pi/agent/skills/<name>` | `~/.pi/agent/agents/<name>.md` | Also symlinks `harnesses/pi-agent/settings.json` to `~/.pi/agent/settings.json`. |

Flags:
- `--dry-run` — print what would happen without touching `$HOME`.
- `--force` — replace an existing real (non-symlink) file/dir at an install target; the original is backed up first (`<name>.bak`, or `settings.old.json` for pi-agent's settings file). Without `--force`, install refuses to clobber anything that isn't already one of its own symlinks.

To remove everything this repo installed for a harness:

```bash
./scripts/uninstall.sh --all
# or: ./scripts/uninstall.sh gemini-cli
```

Uninstall only ever removes symlinks that resolve back into this repo; it never touches real files.

## Global instructions (`CLAUDE.md`)

`harnesses/claude/CLAUDE.md` is Claude Code's global instructions file, applied to every session — it's a single real file, not a per-name directory, and (unlike skills/agents) isn't spliced with any per-harness frontmatter, since only Claude Code reads it. Edit it directly and re-run `./scripts/install.sh claude` to symlink the update into `~/.claude/CLAUDE.md`.

## Adding or editing a skill

1. Create `skills/<name>/SKILL.md` with:
   ```yaml
   ---
   name: <name>              # must match the directory name
   description: ...
   ---

   Body content.
   ```
2. Optionally restrict which harnesses get it with `harnesses: [claude, codex]` (default: every harness with a skills directory).
3. Any other files in the skill's directory (e.g. `references/`, scripts it uses) are copied through as-is; `header-*.yaml` files are not.
4. Skills rarely need a header — most frontmatter fields harnesses currently support (`allowed-tools` etc.) aren't actually read by the target CLI, so don't add one unless a harness genuinely requires extra metadata.

## Adding or editing an agent

1. Create `agents/<name>/AGENT.md` with just `description:` and the body.
2. For each harness that should get this agent, add `agents/<name>/header-<harness>.yaml` containing whatever that harness's frontmatter needs beyond `description` (e.g. `mode:`, `tools:`, `permission:` for OpenCode/Gemini CLI; `tools:`, `thinking:`, `systemPromptMode:` for pi-agent). **An agent only installs to harnesses that have a header file** — there's no implicit "install everywhere" default, since agent frontmatter is entirely harness-specific.
3. For a second variant of the same body under a different name/config (e.g. a `primary` and a `subagent` mode of the same agent), add `header-<harness>.<variant>.yaml` — it builds as `<variant>.md` instead of `<name>.md`.
4. A `harnesses: [...]` key in `AGENT.md` is optional; if present, `build.sh` verifies a header exists for every harness listed there, catching a stale/missing header early.
5. `build.sh` also checks: `name:` in a skill's frontmatter must match its directory; a key must not be set in both the common frontmatter and a header for the same harness; and a header's own `name:` field (used by pi-agent) must match the file it will install as.

## Development

```bash
./scripts/test.sh    # exercises build.sh/install.sh/uninstall.sh against throwaway fixtures,
                     # plus the autofix-pr-local scripts against a mock `gh`
./scripts/build.sh    # build without installing, e.g. to inspect build/<harness>/...
```

## Other useful skills

Skill collections worth borrowing from — install them alongside this repo's, or read them for the patterns:

- [mattpocock/skills](https://github.com/mattpocock/skills) — a broad, actively curated set of general-purpose agent skills.
- [Fission-AI/openspec](https://github.com/Fission-AI/openspec) — spec-driven development for coding agents: agree on the spec before any code is written, so the agent builds what you actually asked for.
- [ykdojo/claude-code-tips](https://github.com/ykdojo/claude-code-tips) - tips akd skills for getting the most out of claude code
- [sirmalloc/ccstatusline](https://github.com/sirmalloc/ccstatusline) - Claude statusline customizer with Cache hot/cold timer
