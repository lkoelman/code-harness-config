# Code Harness Config

**Write a skill once, run it in every coding agent you use.** Claude Code, Codex CLI, Gemini CLI, OpenCode and pi-agent each want their own config directory and their own frontmatter dialect — so the same prompt ends up copy-pasted five times and drifts in four of them. This repo keeps one canonical copy of each skill and agent, splices in whatever per-harness metadata is needed at build time, and symlinks the result into place. Edit the source, re-run `install.sh`, and every harness is up to date.

## Installing TLDR

```bash
# install prerequisites: gh, jq, etc.
./scripts/install-prerequisites.sh
# install all skills and output styles:
./scripts/install.sh --all
# or install/update just one harness:
./scripts/install.sh claude [--project <path>] [--copy]
```

See all options in [Installation](#installing)

## Skills

| Skill | What it does |
|---|---|
| **Pull requests** | |
| [`autofix-pr-local`](skills/autofix-pr-local/SKILL.md) | Shepherds an open PR to green from your machine: loops over failing CI checks, reviewer and bot comments, and base-branch conflicts, fixing the highest-priority signal and committing one fix per issue. |
| [`grill-for-pr`](skills/grill-for-pr/SKILL.md) | Interviews you for the context a diff can't show, then writes a PR title and description engineered for reviewer buy-in — honest, persuasive, and short enough to actually get read. |
| [`pr-description`](skills/pr-description/SKILL.md) | Writes a PR description following code review best practices: shorthand, bullet points and nested lists sized to avoid overloading reviewers. |
| **Engineering & planning** | |
| [`document-architecture`](skills/document-architecture/SKILL.md) | Generates an `ARCHITECTURE.md` for an existing codebase, written as an onboarding entry point for both new developers and coding agents. |
| [`step-back`](skills/step-back/SKILL.md) | Re-evaluates a question, plan, design or piece of code from a staff engineer's perspective, and pushes back when the wrong problem is being solved or a workaround hides the root cause. |
| [`handoff-doc`](skills/handoff-doc/SKILL.md) | Write handoff document so you can /clear or /compact the context window and the next agent can continue the session. |
| **Writing** | |
| [`unslop`](skills/unslop/SKILL.md) | Rewrites existing text to name mechanisms instead of metaphors, qualify ambiguous technical nouns, and replace unmeasurable claims with values. Sources every rewrite from the code rather than inventing a mechanism it cannot verify. |
| [`terse-precise`](skills/terse-precise/SKILL.md) | Writes or rewrites text to the terse, technically precise standard optimized for skimming: name the file, function, condition and effect instead of a metaphor, qualify every ambiguous technical noun, and state both ends of relational jargon. |
| [`claudish-to-english`](skills/claudish-to-english/SKILL.md) | Paraphrases Claude's characteristic prose — contrast-heavy, metaphorical, restatement-prone — into plain English, collapsing repeated propositions and lowering the abstraction level while preserving every fact and logical scope. |
| **Research** | |
| [`zotero-local`](skills/zotero-local/SKILL.md) | Searches, reads and edits your local Zotero library through Zotero's local HTTP API: find papers by title, tag, collection or full text; read metadata, notes and indexed PDF text; get local PDF paths; export BibTeX; format citations. With Zotero 10+, after a one-time "Always Allow" prompt in Zotero: add and edit notes, tag items, manage collections, fix metadata fields, and move items to the trash (never erases). |
| **Documents** | |
| [`pdf2md-docling`](skills/pdf2md-docling/SKILL.md) | Converts PDFs to Markdown with the [docling](https://github.com/docling-project/docling) CLI run through `uvx`, keeping headings and tables and exporting images as PNG files referenced from the Markdown. |
| **Personal workflow** | |
| [`org-agenda-entry`](skills/org-agenda-entry/SKILL.md) | Adds or updates today's (or a requested date's) entry in `Matta-agenda.md` from within a coding session, summarizing progress toward project goals. Edits only the target date's section. |
| [`org-capture-coding-session`](skills/org-capture-coding-session/SKILL.md) | Summarizes a coding or design session into a dated decision log, and links it from the relevant project in `PROJECTS.md`. |
| [`org-daily-checkin`](skills/org-daily-checkin/SKILL.md) | Runs a weekday morning check-in: today's agenda entry, Linear issues needing attention, and anything worth flagging before the day starts. |
| [`org-weekly-checkin`](skills/org-weekly-checkin/SKILL.md) | Runs an end-of-week review: what shipped, `PROJECTS.md` synced against Linear, `TEAM.md` observations triaged, and a short reflection on growth and visibility. |

These four `org-*` skills are personal workflow skills tied to one person's note-taking setup (`Matta-agenda.md`, `PROJECTS.md`, `TEAM.md`) rather than general-purpose dev skills — kept in this repo for the same build/install pipeline, not because they're broadly reusable.

Agent definitions live alongside them in [`agents/`](agents/): `autoplan`, `github-orchestrator-agent`, `github-worker-agent`, `planner-codex`, `plan-writer` and `search-grounding`.

## Layout

```
skills/<name>/SKILL.md               # one skill, shared across every harness
agents/<name>/AGENT.md               # one agent definition, shared across every harness
harnesses/<harness>.conf             # where each harness's skills/agents/settings live
harnesses/pi-agent/settings.json     # pi-agent's settings.json, symlinked in on install
harnesses/claude/output-styles/<name>.md  # Claude Code output style, symlinked in on install
scripts/install-prerequisites.sh     # installs gh, jq and the gh extensions the skills need
scripts/build.sh                     # splices frontmatter, writes build/<harness>/...
scripts/install.sh                   # builds, then symlinks into each harness's config dir
scripts/uninstall.sh                 # removes symlinks this repo created
scripts/test.sh                      # tests for the scripts above and for bundled skill scripts
build/                               # generated output (gitignored)
```

A `SKILL.md` or `AGENT.md` holds the harness-neutral frontmatter (`name`/`description`) and the body. Where a harness needs extra frontmatter it can't share with the others — tool permissions, `mode:`, `model:`, pi-agent's `thinking:`/`systemPromptMode:`, etc. — that goes in a sidecar `header-<harness>.yaml` next to it. At build time the two are spliced together; harnesses that need nothing extra just get the common frontmatter as-is.

## Prerequisites

- [GitHub CLI](https://github.com/cli/cli/blob/trunk/docs/install_linux.md) (`gh`) — used by the `grill-for-pr` skill and the GitHub-driven agents.
- The [`gh-pr-review`](https://github.com/agynio/gh-pr-review) extension, for inline PR review comment workflows: `gh extension install agynio/gh-pr-review`.
- The [`gh-webhook`](https://github.com/cli/gh-webhook) extension, only if you want push-style GitHub event forwarding instead of polling: `gh extension install cli/gh-webhook`. Note it needs admin rights on the repo to register the webhook, plus a local HTTP receiver.
- `jq` — used by the `autofix-pr-local` and `grill-for-pr` skills to read structured JSON.
- `python3` (standard library only) and [Zotero](https://www.zotero.org/download/) 7 or later (10 or later for writes), running, with *Settings → Advanced → Allow other applications on this computer to communicate with Zotero* checked — used by the `zotero-local` skill. `install-prerequisites.sh` does not install these.
- [`uv`](https://docs.astral.sh/uv/getting-started/installation/) — used by the `pdf2md-docling` skill to run docling via `uvx`. Not installed by `install-prerequisites.sh`; install it yourself if you use that skill.

To install all of the above except `uv`, `python3` and Zotero:

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
./scripts/install.sh claude [--project <path>] [--copy]
```

This builds `build/<harness>/...` from `skills/` and `agents/`, then symlinks each skill and agent individually into the harness's config directory — unrelated files already there are left alone. Re-running is safe (idempotent) and picks up any changes after a `git pull`.

| Harness | Skills | Agents | With `--project <p>` | Notes |
|---|---|---|---|---|
| Claude Code | `~/.claude/skills/<name>` | `~/.claude/agents/<name>.md` | `<p>/.claude/{skills,agents,output-styles}` | No agent headers are defined yet, so no agents install here. Also symlinks `harnesses/claude/output-styles/*.md` to `~/.claude/output-styles/<name>.md`. |
| Codex CLI | `~/.codex/skills/<name>` | — | `<p>/.agents/skills` | Codex doesn't support markdown subagent definitions. |
| Gemini CLI | `~/.gemini/skills/<name>` | `~/.gemini/agents/<name>.md` | `<p>/.gemini/{skills,agents}` | Run `/skills reload` after installing/updating. |
| OpenCode | `~/.config/opencode/skills/<name>` | `~/.config/opencode/agents/<name>.md` | `<p>/.opencode/{skills,agents}` | Native path, not `~/.opencode/`. |
| pi-agent | `~/.pi/agent/skills/<name>` | `~/.pi/agent/agents/<name>.md` | `<p>/.pi/{skills,agents}` | Also symlinks `harnesses/pi-agent/settings.json` to `~/.pi/agent/settings.json`. |

Flags:
- `--dry-run` — print what would happen without touching `$HOME`.
- `--force` — replace an existing real (non-symlink) file/dir at an install target; the original is backed up first (`<name>.bak`, or `settings.old.json` for pi-agent's settings file). Without `--force`, install refuses to clobber anything that isn't already one of its own symlinks.
- `--project <path>` — install into one project instead of `$HOME`, at the relative `PROJECT_SKILLS_DIR` / `PROJECT_AGENTS_DIR` / `PROJECT_OUTPUT_STYLES_DIR` paths in each harness's `.conf` (see the table). `<path>` must contain `.git` or `.claude/`, else install exits with an error. A harness with no `PROJECT_*` paths is skipped. `settings.json` and `CLAUDE.md` are user-level and are never installed into a project.
- `--skills a,b` — install only these skills (comma-separated names from `skills/`, or shell glob patterns such as `'org-*'`), and no agents, settings, `CLAUDE.md` or output styles.
- `--output-style` — install only output styles. Combined with `--skills`, installs both the named skills and the output styles.
- `--exclude-skills a,b` — install everything that would otherwise install, except these skills (names or glob patterns, as for `--skills`).
- `--copy` — copy files instead of symlinking them, e.g. so a project can commit them. Re-running over an identical copy is a no-op; a copy that differs from the build (edited locally, or the source changed) is refused without `--force`, like any real file.

Quote glob patterns (`'org-*'`) so your shell passes them through unexpanded. A name or pattern in `--skills` / `--exclude-skills` that matches no skill is an error. Skills not selected are left alone, not removed: selection happens at link time, so earlier installs of other skills stay valid.

```bash
./scripts/install.sh claude --project ~/code/foo --skills unslop,terse-precise
./scripts/install.sh claude --output-style
./scripts/install.sh --all --project . --copy --exclude-skills step-back
./scripts/install.sh --all --exclude-skills 'org-*'
```

To remove everything this repo installed for a harness:

```bash
./scripts/uninstall.sh --all
# or: ./scripts/uninstall.sh gemini-cli
```

Uninstall only ever removes symlinks that resolve back into this repo; it never touches real files. `--project <path>` removes from that project instead of `$HOME`. `--copy` also removes real copies made by `install.sh --copy`, but only copies still identical to a fresh build; an edited copy is kept and reported as `kept modified copy <path>`.

## Global instructions (`CLAUDE.md`)

`scripts/install.sh` symlinks `harnesses/<harness>/CLAUDE.md` to the `CLAUDE_MD_DEST` that harness's `.conf` declares (`~/.claude/CLAUDE.md` for Claude Code) — a single real file, not a per-name directory, and (unlike skills/agents) not spliced with any per-harness frontmatter. No harness ships one right now: the writing-style directives that used to live in `harnesses/claude/CLAUDE.md` are now the [`terse-precise`](skills/terse-precise/SKILL.md) skill, invoked per request instead of applied to every session. Add the file back and re-run `./scripts/install.sh claude` to restore the symlink.

## Output styles

`scripts/install.sh` symlinks each file in `harnesses/<harness>/output-styles/` to `OUTPUT_STYLES_DIR` that harness's `.conf` declares (`~/.claude/output-styles/<name>.md` for Claude Code) — one symlink per file, no splicing, same as `CLAUDE.md`. Output styles are a [Claude Code-specific mechanism](https://code.claude.com/docs/en/output-styles) that replaces the whole system prompt for the session (unlike a skill, invoked per request); no other harness in this repo has an equivalent, so `OUTPUT_STYLES_DIR` is only set in `harnesses/claude.conf`.

This repo ships one: [`terse-precise-technical`](harnesses/claude/output-styles/terse-precise-technical.md), the same terse/ASD-STE100 writing standard as the [`terse-precise`](skills/terse-precise/SKILL.md) skill, but applied to the whole session instead of one request. After installing, activate it in Claude Code with `/config` → **Output style**.

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
                     # the autofix-pr-local and grill-for-pr scripts against a mock `gh`,
                     # and zotero-local's zotero.py against a mock Zotero local API
                     # (scripts/test_zotero_local.py; run alone with `python3 -I <path> -v`)
./scripts/build.sh    # build without installing, e.g. to inspect build/<harness>/...
```

## Useful skills & tools

Skill collections worth borrowing from — install them alongside this repo's, or read them for the patterns:

- [mattpocock/skills](https://github.com/mattpocock/skills) — a broad, actively curated set of general-purpose agent skills.
- [Fission-AI/openspec](https://github.com/Fission-AI/openspec) — spec-driven development for coding agents: agree on the spec before any code is written, so the agent builds what you actually asked for.
- [ykdojo/claude-code-tips](https://github.com/ykdojo/claude-code-tips) - tips akd skills for getting the most out of claude code
- [sirmalloc/ccstatusline](https://github.com/sirmalloc/ccstatusline) - Claude statusline customizer with Cache hot/cold timer
- [Cursor pstack skills](https://github.com/cursor/plugins/tree/main/pstack) - useful skill collection for power devs
- Complendium of claudisms and unslop instructions
  - https://github.com/programasweights/claudish/blob/main/specs/claudish-to-english.md
  - https://claudisms.ai/
  - https://github.com/cursor/plugins/blob/main/pstack/skills/unslop/SKILL.md

