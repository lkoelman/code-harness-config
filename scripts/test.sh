#!/usr/bin/env bash
# Tests for scripts/build.sh, install.sh, uninstall.sh, and the scripts bundled
# with the autofix-pr-local, grill-for-pr and zotero-local skills.
# Each test runs against a throwaway sandbox copy of the scripts plus
# fixture skills/agents/harnesses, so nothing here touches the real
# skills/ or agents/ tree or the real $HOME. The skill-script tests add a
# throwaway git repo and a mock `gh` on $PATH, so they never hit the network.
# The zotero-local tests live in scripts/test_zotero_local.py and run against
# a mock Zotero local API on 127.0.0.1, never a real Zotero.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
FAILURES=0
SANDBOXES=()

pass() { echo "ok - $1"; }
fail() { echo "FAIL - $1"; FAILURES=$((FAILURES + 1)); }

# --------------------------------------------------------------- portability
# macOS ships BSD userland and no GNU coreutils, so three things the tests lean
# on differ from Linux. Each is wrapped once here rather than at every call.

# `mktemp -d` hands back a path under a symlink on macOS (/var -> /private/var),
# while the scripts under test canonicalise with `pwd -P`. Handing out the
# physical path keeps the two spellings from disagreeing.
mktemp_d() {
  local d
  d="$(mktemp -d)" || return 1
  (cd "$d" && pwd -P)
}

# BSD sed wants an argument to -i and GNU sed must not get one, so no single
# spelling works on both. Rewriting through a temp file sidesteps the flag.
# Note the sed scripts here must use a literal tab ($'\t'), not \t: that escape
# is a GNU extension too.
sed_inplace() {
  local script="$1" file="$2" tmp
  tmp="$(mktemp)" || return 1
  if sed "$script" "$file" >"$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}

# GNU `timeout` is not on macOS at all. Fall back to a plain watchdog; the
# 124 exit status matches what the real thing reports on expiry.
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
    return $?
  fi
  "$@" &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      kill -TERM "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

cleanup() {
  for d in "${SANDBOXES[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup EXIT

# Creates a fresh sandbox with copies of the scripts under test and empty
# skills/agents/harnesses dirs. Prints the sandbox path.
new_sandbox() {
  local d
  d="$(mktemp_d)"
  SANDBOXES+=("$d")
  mkdir -p "$d/scripts" "$d/skills" "$d/agents" "$d/harnesses"
  cp "$REPO/scripts/build.sh" "$REPO/scripts/install.sh" "$REPO/scripts/uninstall.sh" "$d/scripts/"
  chmod +x "$d"/scripts/*.sh
  echo "$d"
}

write_alpha_conf() {
  local sandbox="$1"
  cat >"$sandbox/harnesses/alpha.conf" <<'EOF'
SKILLS_DIR="$HOME/.alpha/skills"
AGENTS_DIR="$HOME/.alpha/agents"
EOF
}

write_beta_conf() {
  local sandbox="$1"
  cat >"$sandbox/harnesses/beta.conf" <<'EOF'
SKILLS_DIR="$HOME/.beta/skills"
AGENTS_DIR=""
EOF
}

# alpha.conf with a CLAUDE_MD_DEST, plus the harnesses/alpha/CLAUDE.md fixture
# it points at (mirrors the pi-agent settings.json pattern).
write_alpha_conf_with_claude_md() {
  local sandbox="$1"
  cat >"$sandbox/harnesses/alpha.conf" <<'EOF'
SKILLS_DIR="$HOME/.alpha/skills"
AGENTS_DIR="$HOME/.alpha/agents"
CLAUDE_MD_DEST="$HOME/CLAUDE.md"
EOF
  mkdir -p "$sandbox/harnesses/alpha"
  echo "alpha global instructions" >"$sandbox/harnesses/alpha/CLAUDE.md"
}

# alpha.conf with an OUTPUT_STYLES_DIR, plus one fixture style file under
# harnesses/alpha/output-styles/ (mirrors the CLAUDE.md pattern, but a
# directory of files rather than a single destination file).
write_alpha_conf_with_output_styles() {
  local sandbox="$1"
  cat >"$sandbox/harnesses/alpha.conf" <<'EOF'
SKILLS_DIR="$HOME/.alpha/skills"
AGENTS_DIR="$HOME/.alpha/agents"
OUTPUT_STYLES_DIR="$HOME/.alpha/output-styles"
EOF
  mkdir -p "$sandbox/harnesses/alpha/output-styles"
  cat >"$sandbox/harnesses/alpha/output-styles/sample-style.md" <<'EOF'
---
name: sample-style
description: a sample output style
---

Sample style body.
EOF
}

# alpha.conf with $HOME paths plus relative PROJECT_* paths, one output-style
# fixture, skills widget + gadget and agent helper — the full set of
# categories the --project/--skills/--exclude-skills/--output-style
# selectors choose between.
write_alpha_project_fixture() {
  local sandbox="$1"
  cat >"$sandbox/harnesses/alpha.conf" <<'EOF'
SKILLS_DIR="$HOME/.alpha/skills"
AGENTS_DIR="$HOME/.alpha/agents"
OUTPUT_STYLES_DIR="$HOME/.alpha/output-styles"
PROJECT_SKILLS_DIR=".alpha/skills"
PROJECT_AGENTS_DIR=".alpha/agents"
PROJECT_OUTPUT_STYLES_DIR=".alpha/output-styles"
EOF
  mkdir -p "$sandbox/harnesses/alpha/output-styles"
  echo "Sample style body." >"$sandbox/harnesses/alpha/output-styles/sample-style.md"
  local s
  for s in widget gadget; do
    mkdir -p "$sandbox/skills/$s"
    printf -- '---\nname: %s\ndescription: %s things\n---\n\n%s body.\n' "$s" "$s" "$s" >"$sandbox/skills/$s/SKILL.md"
  done
  mkdir -p "$sandbox/agents/helper"
  printf -- '---\ndescription: helps\n---\n\nHelp body.\n' >"$sandbox/agents/helper/AGENT.md"
  echo "mode: primary" >"$sandbox/agents/helper/header-alpha.yaml"
}

# A fake project root (has .git/), printed physical path.
new_project() {
  local p; p="$(mktemp_d)"; SANDBOXES+=("$p")
  mkdir -p "$p/.git"
  echo "$p"
}

test_zotero_local_cli() {
  local name="skill zotero-local: zotero.py against a mock local API"
  local out
  if ! command -v python3 >/dev/null 2>&1; then
    fail "$name (python3 not found)"; return
  fi
  # -I: ignore PYTHON* env vars and keep cwd off sys.path.
  out="$(python3 -I "$REPO/scripts/test_zotero_local.py" 2>&1)" \
    || { echo "$out"; fail "$name"; return; }
  pass "$name"
}

# ---------------------------------------------------------------------------
test_splice_and_passthrough() {
  local name="build: splices frontmatter, preserves body, copies supporting files"
  local sandbox; sandbox="$(new_sandbox)"
  write_alpha_conf "$sandbox"

  mkdir -p "$sandbox/skills/widget"
  cat >"$sandbox/skills/widget/SKILL.md" <<'EOF'
---
name: widget
description: does widget things
---

Widget body.
EOF
  echo "hello" >"$sandbox/skills/widget/notes.txt"

  mkdir -p "$sandbox/agents/helper"
  cat >"$sandbox/agents/helper/AGENT.md" <<'EOF'
---
description: helps
---

Help body.
EOF
  cat >"$sandbox/agents/helper/header-alpha.yaml" <<'EOF'
mode: primary
tools:
  bash: true
EOF

  if ! "$sandbox/scripts/build.sh" alpha >"$sandbox/build.log" 2>&1; then
    fail "$name (build.sh exited nonzero)"; cat "$sandbox/build.log"; return
  fi

  local skill_out="$sandbox/build/alpha/skills/widget/SKILL.md"
  if [ ! -f "$skill_out" ]; then fail "$name (missing skill output)"; return; fi
  grep -q '^name: widget$' "$skill_out" || { fail "$name (name missing in skill output)"; return; }
  grep -q '^description: does widget things$' "$skill_out" || { fail "$name (description missing)"; return; }
  grep -qx 'Widget body.' "$skill_out" || { fail "$name (body not preserved)"; return; }

  if [ ! -f "$sandbox/build/alpha/skills/widget/notes.txt" ]; then
    fail "$name (supporting file not copied)"; return
  fi
  [ "$(cat "$sandbox/build/alpha/skills/widget/notes.txt")" = "hello" ] || { fail "$name (supporting file content changed)"; return; }

  local agent_out="$sandbox/build/alpha/agents/helper.md"
  if [ ! -f "$agent_out" ]; then fail "$name (missing agent output)"; return; fi
  grep -q '^description: helps$' "$agent_out" || { fail "$name (agent description missing)"; return; }
  grep -q '^mode: primary$' "$agent_out" || { fail "$name (header mode missing)"; return; }
  grep -q '^  bash: true$' "$agent_out" || { fail "$name (header tools missing)"; return; }
  grep -qx 'Help body.' "$agent_out" || { fail "$name (agent body not preserved)"; return; }
  [ -f "$sandbox/build/alpha/agents/header-alpha.yaml" ] && { fail "$name (header leaked as standalone file)"; return; }

  pass "$name"
}

# ---------------------------------------------------------------------------
test_harnesses_targeting() {
  local name="build: harnesses: key restricts which harnesses get a skill"
  local sandbox; sandbox="$(new_sandbox)"
  write_alpha_conf "$sandbox"
  write_beta_conf "$sandbox"

  mkdir -p "$sandbox/skills/restricted"
  cat >"$sandbox/skills/restricted/SKILL.md" <<'EOF'
---
name: restricted
description: only for alpha
harnesses: [alpha]
---

Body.
EOF

  if ! "$sandbox/scripts/build.sh" >"$sandbox/build.log" 2>&1; then
    fail "$name (build.sh exited nonzero)"; cat "$sandbox/build.log"; return
  fi

  [ -f "$sandbox/build/alpha/skills/restricted/SKILL.md" ] || { fail "$name (missing for targeted harness)"; return; }
  [ -e "$sandbox/build/beta/skills/restricted" ] && { fail "$name (installed to non-targeted harness)"; return; }
  grep -q '^harnesses:' "$sandbox/build/alpha/skills/restricted/SKILL.md" && { fail "$name (harnesses key leaked into output)"; return; }

  pass "$name"
}

# ---------------------------------------------------------------------------
test_variant_headers() {
  local name="build: variant headers produce extra outputs under variant name"
  local sandbox; sandbox="$(new_sandbox)"
  write_alpha_conf "$sandbox"

  mkdir -p "$sandbox/agents/searcher"
  cat >"$sandbox/agents/searcher/AGENT.md" <<'EOF'
---
description: searches things
---

Search body.
EOF
  cat >"$sandbox/agents/searcher/header-alpha.yaml" <<'EOF'
mode: primary
EOF
  cat >"$sandbox/agents/searcher/header-alpha.searcher-sub.yaml" <<'EOF'
mode: subagent
EOF

  if ! "$sandbox/scripts/build.sh" alpha >"$sandbox/build.log" 2>&1; then
    fail "$name (build.sh exited nonzero)"; cat "$sandbox/build.log"; return
  fi

  local primary="$sandbox/build/alpha/agents/searcher.md"
  local sub="$sandbox/build/alpha/agents/searcher-sub.md"
  [ -f "$primary" ] || { fail "$name (missing primary variant output)"; return; }
  [ -f "$sub" ] || { fail "$name (missing sub variant output)"; return; }
  grep -q '^mode: primary$' "$primary" || { fail "$name (primary mode wrong)"; return; }
  grep -q '^mode: subagent$' "$sub" || { fail "$name (sub mode wrong)"; return; }
  grep -qx 'Search body.' "$primary" || { fail "$name (primary body wrong)"; return; }
  grep -qx 'Search body.' "$sub" || { fail "$name (sub body wrong)"; return; }

  pass "$name"
}

# ---------------------------------------------------------------------------
test_lint_name_dir_mismatch() {
  local name="build: lint fails when SKILL.md name != directory name"
  local sandbox; sandbox="$(new_sandbox)"
  write_alpha_conf "$sandbox"

  mkdir -p "$sandbox/skills/foo"
  cat >"$sandbox/skills/foo/SKILL.md" <<'EOF'
---
name: bar
description: mismatched name
---

Body.
EOF

  if "$sandbox/scripts/build.sh" >"$sandbox/build.log" 2>&1; then
    fail "$name (build.sh should have failed)"; return
  fi
  grep -qi 'foo' "$sandbox/build.log" || { fail "$name (error doesn't mention the mismatch)"; return; }

  pass "$name"
}

# ---------------------------------------------------------------------------
test_lint_duplicate_key() {
  local name="build: lint fails when a key is duplicated between common frontmatter and a header"
  local sandbox; sandbox="$(new_sandbox)"
  write_alpha_conf "$sandbox"

  mkdir -p "$sandbox/agents/dup"
  cat >"$sandbox/agents/dup/AGENT.md" <<'EOF'
---
description: has a duplicate key
mode: primary
---

Body.
EOF
  cat >"$sandbox/agents/dup/header-alpha.yaml" <<'EOF'
mode: subagent
EOF

  if "$sandbox/scripts/build.sh" >"$sandbox/build.log" 2>&1; then
    fail "$name (build.sh should have failed)"; return
  fi
  grep -qi 'mode' "$sandbox/build.log" || { fail "$name (error doesn't mention the duplicate key)"; return; }

  pass "$name"
}

# ---------------------------------------------------------------------------
test_lint_missing_header_for_targeted_harness() {
  local name="build: lint fails when an agent targets a harness with no header file"
  local sandbox; sandbox="$(new_sandbox)"
  write_alpha_conf "$sandbox"

  mkdir -p "$sandbox/agents/orphan"
  cat >"$sandbox/agents/orphan/AGENT.md" <<'EOF'
---
description: targets alpha but has no header
harnesses: [alpha]
---

Body.
EOF

  if "$sandbox/scripts/build.sh" >"$sandbox/build.log" 2>&1; then
    fail "$name (build.sh should have failed)"; return
  fi
  grep -qi 'orphan' "$sandbox/build.log" || { fail "$name (error doesn't mention the agent)"; return; }

  pass "$name"
}

# ---------------------------------------------------------------------------
test_install_uninstall_idempotent() {
  local name="install/uninstall: symlinks created, removed, idempotent"
  local sandbox; sandbox="$(new_sandbox)"
  write_alpha_conf "$sandbox"

  mkdir -p "$sandbox/skills/widget"
  cat >"$sandbox/skills/widget/SKILL.md" <<'EOF'
---
name: widget
description: does widget things
---

Widget body.
EOF

  mkdir -p "$sandbox/agents/helper"
  cat >"$sandbox/agents/helper/AGENT.md" <<'EOF'
---
description: helps
---

Help body.
EOF
  cat >"$sandbox/agents/helper/header-alpha.yaml" <<'EOF'
mode: primary
EOF

  local fake_home; fake_home="$(mktemp_d)"; SANDBOXES+=("$fake_home")

  if ! HOME="$fake_home" "$sandbox/scripts/install.sh" alpha >"$sandbox/install.log" 2>&1; then
    fail "$name (install.sh exited nonzero)"; cat "$sandbox/install.log"; return
  fi

  local skill_link="$fake_home/.alpha/skills/widget"
  local agent_link="$fake_home/.alpha/agents/helper.md"
  [ -L "$skill_link" ] || { fail "$name (skill symlink not created)"; return; }
  [ -L "$agent_link" ] || { fail "$name (agent symlink not created)"; return; }
  [ "$(readlink -f "$skill_link")" = "$(readlink -f "$sandbox/build/alpha/skills/widget")" ] || { fail "$name (skill symlink target wrong)"; return; }
  [ "$(readlink -f "$agent_link")" = "$(readlink -f "$sandbox/build/alpha/agents/helper.md")" ] || { fail "$name (agent symlink target wrong)"; return; }

  # reinstall is idempotent
  if ! HOME="$fake_home" "$sandbox/scripts/install.sh" alpha >"$sandbox/install2.log" 2>&1; then
    fail "$name (reinstall exited nonzero)"; cat "$sandbox/install2.log"; return
  fi
  [ -L "$skill_link" ] || { fail "$name (skill symlink gone after reinstall)"; return; }

  if ! HOME="$fake_home" "$sandbox/scripts/uninstall.sh" alpha >"$sandbox/uninstall.log" 2>&1; then
    fail "$name (uninstall.sh exited nonzero)"; cat "$sandbox/uninstall.log"; return
  fi
  [ -e "$skill_link" ] && { fail "$name (skill symlink still present after uninstall)"; return; }
  [ -e "$agent_link" ] && { fail "$name (agent symlink still present after uninstall)"; return; }

  # uninstalling again is a harmless no-op
  if ! HOME="$fake_home" "$sandbox/scripts/uninstall.sh" alpha >"$sandbox/uninstall2.log" 2>&1; then
    fail "$name (second uninstall exited nonzero)"; cat "$sandbox/uninstall2.log"; return
  fi

  pass "$name"
}

# ---------------------------------------------------------------------------
test_install_guardrail_and_force() {
  local name="install: refuses to clobber a real file without --force, backs it up with --force"
  local sandbox; sandbox="$(new_sandbox)"
  write_alpha_conf "$sandbox"

  mkdir -p "$sandbox/skills/widget"
  cat >"$sandbox/skills/widget/SKILL.md" <<'EOF'
---
name: widget
description: does widget things
---

Widget body.
EOF

  local fake_home; fake_home="$(mktemp_d)"; SANDBOXES+=("$fake_home")
  mkdir -p "$fake_home/.alpha/skills/widget"
  echo "keep-me" >"$fake_home/.alpha/skills/widget/keep-me.txt"

  if HOME="$fake_home" "$sandbox/scripts/install.sh" alpha >"$sandbox/install.log" 2>&1; then
    fail "$name (install.sh should have refused without --force)"; return
  fi
  [ -f "$fake_home/.alpha/skills/widget/keep-me.txt" ] || { fail "$name (real file destroyed without --force)"; return; }
  [ "$(cat "$fake_home/.alpha/skills/widget/keep-me.txt")" = "keep-me" ] || { fail "$name (real file content changed without --force)"; return; }

  if ! HOME="$fake_home" "$sandbox/scripts/install.sh" alpha --force >"$sandbox/install-force.log" 2>&1; then
    fail "$name (install.sh --force should have succeeded)"; cat "$sandbox/install-force.log"; return
  fi
  [ -L "$fake_home/.alpha/skills/widget" ] || { fail "$name (target not a symlink after --force)"; return; }

  local backup
  backup="$(find "$fake_home/.alpha/skills" -maxdepth 1 -name 'widget.bak*' | head -n1)"
  [ -n "$backup" ] || { fail "$name (no backup of clobbered real dir found)"; return; }
  [ -f "$backup/keep-me.txt" ] || { fail "$name (backup missing original content)"; return; }

  pass "$name"
}

# ---------------------------------------------------------------------------
test_install_dry_run() {
  local name="install: --dry-run writes nothing under HOME"
  local sandbox; sandbox="$(new_sandbox)"
  write_alpha_conf "$sandbox"

  mkdir -p "$sandbox/skills/widget"
  cat >"$sandbox/skills/widget/SKILL.md" <<'EOF'
---
name: widget
description: does widget things
---

Widget body.
EOF

  local fake_home; fake_home="$(mktemp_d)"; SANDBOXES+=("$fake_home")

  if ! HOME="$fake_home" "$sandbox/scripts/install.sh" alpha --dry-run >"$sandbox/install.log" 2>&1; then
    fail "$name (install.sh --dry-run exited nonzero)"; cat "$sandbox/install.log"; return
  fi

  if [ -e "$fake_home/.alpha" ]; then
    fail "$name (dry-run created files under HOME)"; return
  fi
  [ -f "$sandbox/build/alpha/skills/widget/SKILL.md" ] || { fail "$name (dry-run should still (re)build)"; return; }

  pass "$name"
}

# ---------------------------------------------------------------------------
test_install_claude_md_symlink() {
  local name="install/uninstall: CLAUDE_MD_DEST symlinks harnesses/<h>/CLAUDE.md, idempotent"
  local sandbox; sandbox="$(new_sandbox)"
  write_alpha_conf_with_claude_md "$sandbox"

  local fake_home; fake_home="$(mktemp_d)"; SANDBOXES+=("$fake_home")

  if ! HOME="$fake_home" "$sandbox/scripts/install.sh" alpha >"$sandbox/install.log" 2>&1; then
    fail "$name (install.sh exited nonzero)"; cat "$sandbox/install.log"; return
  fi

  local dest="$fake_home/CLAUDE.md"
  [ -L "$dest" ] || { fail "$name (CLAUDE.md symlink not created)"; return; }
  [ "$(readlink -f "$dest")" = "$(readlink -f "$sandbox/harnesses/alpha/CLAUDE.md")" ] \
    || { fail "$name (CLAUDE.md symlink target wrong)"; return; }
  [ "$(cat "$dest")" = "alpha global instructions" ] || { fail "$name (CLAUDE.md content wrong)"; return; }

  # reinstall is idempotent
  if ! HOME="$fake_home" "$sandbox/scripts/install.sh" alpha >"$sandbox/install2.log" 2>&1; then
    fail "$name (reinstall exited nonzero)"; cat "$sandbox/install2.log"; return
  fi
  [ -L "$dest" ] || { fail "$name (CLAUDE.md symlink gone after reinstall)"; return; }

  if ! HOME="$fake_home" "$sandbox/scripts/uninstall.sh" alpha >"$sandbox/uninstall.log" 2>&1; then
    fail "$name (uninstall.sh exited nonzero)"; cat "$sandbox/uninstall.log"; return
  fi
  [ -e "$dest" ] && { fail "$name (CLAUDE.md symlink still present after uninstall)"; return; }

  # uninstalling again is a harmless no-op
  if ! HOME="$fake_home" "$sandbox/scripts/uninstall.sh" alpha >"$sandbox/uninstall2.log" 2>&1; then
    fail "$name (second uninstall exited nonzero)"; cat "$sandbox/uninstall2.log"; return
  fi

  pass "$name"
}

# ---------------------------------------------------------------------------
test_install_claude_md_guardrail_and_force() {
  local name="install: refuses to clobber a real CLAUDE.md without --force, backs it up with --force"
  local sandbox; sandbox="$(new_sandbox)"
  write_alpha_conf_with_claude_md "$sandbox"

  local fake_home; fake_home="$(mktemp_d)"; SANDBOXES+=("$fake_home")
  echo "keep-me" >"$fake_home/CLAUDE.md"

  if HOME="$fake_home" "$sandbox/scripts/install.sh" alpha >"$sandbox/install.log" 2>&1; then
    fail "$name (install.sh should have refused without --force)"; return
  fi
  [ "$(cat "$fake_home/CLAUDE.md")" = "keep-me" ] || { fail "$name (real file destroyed without --force)"; return; }

  if ! HOME="$fake_home" "$sandbox/scripts/install.sh" alpha --force >"$sandbox/install-force.log" 2>&1; then
    fail "$name (install.sh --force should have succeeded)"; cat "$sandbox/install-force.log"; return
  fi
  [ -L "$fake_home/CLAUDE.md" ] || { fail "$name (target not a symlink after --force)"; return; }
  [ -f "$fake_home/CLAUDE.md.bak" ] || { fail "$name (no backup of clobbered real file found)"; return; }
  [ "$(cat "$fake_home/CLAUDE.md.bak")" = "keep-me" ] || { fail "$name (backup missing original content)"; return; }

  pass "$name"
}

# ---------------------------------------------------------------------------
test_install_output_styles_symlink() {
  local name="install/uninstall: OUTPUT_STYLES_DIR symlinks harnesses/<h>/output-styles/*, idempotent"
  local sandbox; sandbox="$(new_sandbox)"
  write_alpha_conf_with_output_styles "$sandbox"

  local fake_home; fake_home="$(mktemp_d)"; SANDBOXES+=("$fake_home")

  if ! HOME="$fake_home" "$sandbox/scripts/install.sh" alpha >"$sandbox/install.log" 2>&1; then
    fail "$name (install.sh exited nonzero)"; cat "$sandbox/install.log"; return
  fi

  local dest="$fake_home/.alpha/output-styles/sample-style.md"
  [ -L "$dest" ] || { fail "$name (output style symlink not created)"; return; }
  [ "$(readlink -f "$dest")" = "$(readlink -f "$sandbox/harnesses/alpha/output-styles/sample-style.md")" ] \
    || { fail "$name (output style symlink target wrong)"; return; }
  grep -q "Sample style body." "$dest" || { fail "$name (output style content wrong)"; return; }

  # reinstall is idempotent
  if ! HOME="$fake_home" "$sandbox/scripts/install.sh" alpha >"$sandbox/install2.log" 2>&1; then
    fail "$name (reinstall exited nonzero)"; cat "$sandbox/install2.log"; return
  fi
  [ -L "$dest" ] || { fail "$name (output style symlink gone after reinstall)"; return; }

  if ! HOME="$fake_home" "$sandbox/scripts/uninstall.sh" alpha >"$sandbox/uninstall.log" 2>&1; then
    fail "$name (uninstall.sh exited nonzero)"; cat "$sandbox/uninstall.log"; return
  fi
  [ -e "$dest" ] && { fail "$name (output style symlink still present after uninstall)"; return; }

  # uninstalling again is a harmless no-op
  if ! HOME="$fake_home" "$sandbox/scripts/uninstall.sh" alpha >"$sandbox/uninstall2.log" 2>&1; then
    fail "$name (second uninstall exited nonzero)"; cat "$sandbox/uninstall2.log"; return
  fi

  pass "$name"
}

# ---------------------------------------------------------------------------
test_install_output_styles_prune_stale() {
  local name="install: prunes a stale output-style symlink after its source file is removed"
  local sandbox; sandbox="$(new_sandbox)"
  write_alpha_conf_with_output_styles "$sandbox"
  cat >"$sandbox/harnesses/alpha/output-styles/other-style.md" <<'EOF'
---
name: other-style
description: another sample output style
---

Other style body.
EOF

  local fake_home; fake_home="$(mktemp_d)"; SANDBOXES+=("$fake_home")

  if ! HOME="$fake_home" "$sandbox/scripts/install.sh" alpha >"$sandbox/install.log" 2>&1; then
    fail "$name (install.sh exited nonzero)"; cat "$sandbox/install.log"; return
  fi
  local kept="$fake_home/.alpha/output-styles/sample-style.md"
  local removed="$fake_home/.alpha/output-styles/other-style.md"
  [ -L "$kept" ] || { fail "$name (sample-style symlink not created)"; return; }
  [ -L "$removed" ] || { fail "$name (other-style symlink not created)"; return; }

  rm "$sandbox/harnesses/alpha/output-styles/other-style.md"

  if ! HOME="$fake_home" "$sandbox/scripts/install.sh" alpha >"$sandbox/install2.log" 2>&1; then
    fail "$name (reinstall exited nonzero)"; cat "$sandbox/install2.log"; return
  fi
  [ -e "$removed" ] && { fail "$name (stale other-style symlink not pruned)"; return; }
  [ -L "$kept" ] || { fail "$name (sample-style symlink pruned by mistake)"; return; }

  pass "$name"
}

# ---------------------------------------------------------------------------
test_install_project_requires_root() {
  local name="install: --project refuses a dir without .git or .claude/, accepts .claude/ alone"
  local sandbox; sandbox="$(new_sandbox)"
  write_alpha_project_fixture "$sandbox"
  local fake_home; fake_home="$(mktemp_d)"; SANDBOXES+=("$fake_home")
  local proj; proj="$(mktemp_d)"; SANDBOXES+=("$proj")

  if HOME="$fake_home" "$sandbox/scripts/install.sh" alpha --project "$proj" >"$sandbox/install.log" 2>&1; then
    fail "$name (install.sh should have refused a non-project dir)"; return
  fi
  grep -q '\.git' "$sandbox/install.log" || { fail "$name (error doesn't mention .git)"; return; }
  [ -e "$proj/.alpha" ] && { fail "$name (created files in a non-project dir)"; return; }

  mkdir -p "$proj/.claude"
  if ! HOME="$fake_home" "$sandbox/scripts/install.sh" alpha --project "$proj" >"$sandbox/install2.log" 2>&1; then
    fail "$name (install.sh should accept a dir with .claude/)"; cat "$sandbox/install2.log"; return
  fi
  [ -L "$proj/.alpha/skills/widget" ] || { fail "$name (skill not installed into .claude/-only project)"; return; }

  if HOME="$fake_home" "$sandbox/scripts/install.sh" alpha --project >"$sandbox/install3.log" 2>&1; then
    fail "$name (--project with no value should fail)"; return
  fi

  pass "$name"
}

# ---------------------------------------------------------------------------
test_install_project_symlinks_and_uninstall() {
  local name="install/uninstall: --project links into <project>/PROJECT_* dirs, not HOME"
  local sandbox; sandbox="$(new_sandbox)"
  write_alpha_project_fixture "$sandbox"
  write_beta_conf "$sandbox"
  local fake_home; fake_home="$(mktemp_d)"; SANDBOXES+=("$fake_home")
  local proj; proj="$(new_project)"

  if ! HOME="$fake_home" "$sandbox/scripts/install.sh" alpha beta --project "$proj" >"$sandbox/install.log" 2>&1; then
    fail "$name (install.sh exited nonzero)"; cat "$sandbox/install.log"; return
  fi
  [ -L "$proj/.alpha/skills/widget" ] || { fail "$name (skill not linked into project)"; return; }
  [ -L "$proj/.alpha/agents/helper.md" ] || { fail "$name (agent not linked into project)"; return; }
  [ -L "$proj/.alpha/output-styles/sample-style.md" ] || { fail "$name (output style not linked into project)"; return; }
  [ -e "$fake_home/.alpha" ] && { fail "$name (project install wrote under HOME)"; return; }
  grep -q 'skipping beta' "$sandbox/install.log" || { fail "$name (harness without PROJECT_* not reported as skipped)"; return; }
  [ -e "$proj/.beta" ] && { fail "$name (harness without PROJECT_* installed anyway)"; return; }

  if ! HOME="$fake_home" "$sandbox/scripts/uninstall.sh" alpha beta --project "$proj" >"$sandbox/uninstall.log" 2>&1; then
    fail "$name (uninstall.sh exited nonzero)"; cat "$sandbox/uninstall.log"; return
  fi
  [ -e "$proj/.alpha/skills/widget" ] && { fail "$name (skill link still present after uninstall)"; return; }
  [ -e "$proj/.alpha/agents/helper.md" ] && { fail "$name (agent link still present after uninstall)"; return; }
  [ -e "$proj/.alpha/output-styles/sample-style.md" ] && { fail "$name (output style link still present after uninstall)"; return; }

  pass "$name"
}

# ---------------------------------------------------------------------------
test_install_skill_selectors() {
  local name="install: --skills / --exclude-skills / --output-style narrow what installs"
  local sandbox; sandbox="$(new_sandbox)"
  write_alpha_project_fixture "$sandbox"
  local h

  h="$(mktemp_d)"; SANDBOXES+=("$h")
  if ! HOME="$h" "$sandbox/scripts/install.sh" alpha --skills widget >"$sandbox/i1.log" 2>&1; then
    fail "$name (--skills exited nonzero)"; cat "$sandbox/i1.log"; return
  fi
  [ -L "$h/.alpha/skills/widget" ] || { fail "$name (--skills: selected skill missing)"; return; }
  [ -e "$h/.alpha/skills/gadget" ] && { fail "$name (--skills: unselected skill installed)"; return; }
  [ -e "$h/.alpha/agents" ] && { fail "$name (--skills: agents installed)"; return; }
  [ -e "$h/.alpha/output-styles" ] && { fail "$name (--skills: output styles installed)"; return; }

  h="$(mktemp_d)"; SANDBOXES+=("$h")
  if ! HOME="$h" "$sandbox/scripts/install.sh" alpha --exclude-skills widget >"$sandbox/i2.log" 2>&1; then
    fail "$name (--exclude-skills exited nonzero)"; cat "$sandbox/i2.log"; return
  fi
  [ -e "$h/.alpha/skills/widget" ] && { fail "$name (--exclude-skills: excluded skill installed)"; return; }
  [ -L "$h/.alpha/skills/gadget" ] || { fail "$name (--exclude-skills: other skill missing)"; return; }
  [ -L "$h/.alpha/agents/helper.md" ] || { fail "$name (--exclude-skills: agent missing)"; return; }
  [ -L "$h/.alpha/output-styles/sample-style.md" ] || { fail "$name (--exclude-skills: output style missing)"; return; }

  h="$(mktemp_d)"; SANDBOXES+=("$h")
  if ! HOME="$h" "$sandbox/scripts/install.sh" alpha --output-style >"$sandbox/i3.log" 2>&1; then
    fail "$name (--output-style exited nonzero)"; cat "$sandbox/i3.log"; return
  fi
  [ -L "$h/.alpha/output-styles/sample-style.md" ] || { fail "$name (--output-style: style missing)"; return; }
  [ -e "$h/.alpha/skills" ] && { fail "$name (--output-style: skills installed)"; return; }
  [ -e "$h/.alpha/agents" ] && { fail "$name (--output-style: agents installed)"; return; }

  h="$(mktemp_d)"; SANDBOXES+=("$h")
  if ! HOME="$h" "$sandbox/scripts/install.sh" alpha --output-style --skills widget >"$sandbox/i4.log" 2>&1; then
    fail "$name (--output-style --skills exited nonzero)"; cat "$sandbox/i4.log"; return
  fi
  [ -L "$h/.alpha/output-styles/sample-style.md" ] || { fail "$name (union: style missing)"; return; }
  [ -L "$h/.alpha/skills/widget" ] || { fail "$name (union: skill missing)"; return; }
  [ -e "$h/.alpha/agents" ] && { fail "$name (union: agents installed)"; return; }

  h="$(mktemp_d)"; SANDBOXES+=("$h")
  if HOME="$h" "$sandbox/scripts/install.sh" alpha --skills widget,nosuch >"$sandbox/i5.log" 2>&1; then
    fail "$name (--skills with unknown name should fail)"; return
  fi
  grep -q nosuch "$sandbox/i5.log" || { fail "$name (error doesn't name the unknown skill)"; return; }
  [ -e "$h/.alpha" ] && { fail "$name (unknown skill still installed something)"; return; }
  if HOME="$h" "$sandbox/scripts/install.sh" alpha --exclude-skills nosuch >"$sandbox/i6.log" 2>&1; then
    fail "$name (--exclude-skills with unknown name should fail)"; return
  fi

  pass "$name"
}

# ---------------------------------------------------------------------------
test_install_skill_patterns() {
  local name="install: --skills / --exclude-skills entries are glob patterns"
  local sandbox; sandbox="$(new_sandbox)"
  write_alpha_project_fixture "$sandbox"
  mkdir -p "$sandbox/skills/org-one"
  printf -- '---\nname: org-one\ndescription: org things\n---\n\nOrg body.\n' >"$sandbox/skills/org-one/SKILL.md"
  local h

  # Run from a cwd holding a file that matches the pattern, so a pattern the
  # script itself glob-expands against the filesystem would turn into 'org-x'.
  local cwd; cwd="$(mktemp_d)"; SANDBOXES+=("$cwd")
  touch "$cwd/org-x"
  cd "$cwd" || { fail "$name (cd failed)"; return; }

  h="$(mktemp_d)"; SANDBOXES+=("$h")
  if ! HOME="$h" "$sandbox/scripts/install.sh" alpha --exclude-skills 'org-*' >"$sandbox/p1.log" 2>&1; then
    fail "$name (--exclude-skills 'org-*' exited nonzero)"; cat "$sandbox/p1.log"; cd "$REPO"; return
  fi
  [ -e "$h/.alpha/skills/org-one" ] && { fail "$name (--exclude-skills 'org-*': org-one installed)"; cd "$REPO"; return; }
  [ -L "$h/.alpha/skills/widget" ] || { fail "$name (--exclude-skills 'org-*': widget missing)"; cd "$REPO"; return; }
  [ -L "$h/.alpha/skills/gadget" ] || { fail "$name (--exclude-skills 'org-*': gadget missing)"; cd "$REPO"; return; }
  [ -L "$h/.alpha/agents/helper.md" ] || { fail "$name (--exclude-skills 'org-*': agent missing)"; cd "$REPO"; return; }

  h="$(mktemp_d)"; SANDBOXES+=("$h")
  if ! HOME="$h" "$sandbox/scripts/install.sh" alpha --skills 'w*' >"$sandbox/p2.log" 2>&1; then
    fail "$name (--skills 'w*' exited nonzero)"; cat "$sandbox/p2.log"; cd "$REPO"; return
  fi
  [ -L "$h/.alpha/skills/widget" ] || { fail "$name (--skills 'w*': widget missing)"; cd "$REPO"; return; }
  [ -e "$h/.alpha/skills/gadget" ] && { fail "$name (--skills 'w*': gadget installed)"; cd "$REPO"; return; }
  [ -e "$h/.alpha/skills/org-one" ] && { fail "$name (--skills 'w*': org-one installed)"; cd "$REPO"; return; }
  [ -e "$h/.alpha/agents" ] && { fail "$name (--skills 'w*': agents installed)"; cd "$REPO"; return; }

  h="$(mktemp_d)"; SANDBOXES+=("$h")
  if ! HOME="$h" "$sandbox/scripts/install.sh" alpha --skills 'widget,g?dget' >"$sandbox/p3.log" 2>&1; then
    fail "$name (--skills 'widget,g?dget' exited nonzero)"; cat "$sandbox/p3.log"; cd "$REPO"; return
  fi
  [ -L "$h/.alpha/skills/widget" ] || { fail "$name (mixed list: widget missing)"; cd "$REPO"; return; }
  [ -L "$h/.alpha/skills/gadget" ] || { fail "$name (mixed list: gadget missing)"; cd "$REPO"; return; }
  [ -e "$h/.alpha/skills/org-one" ] && { fail "$name (mixed list: org-one installed)"; cd "$REPO"; return; }

  h="$(mktemp_d)"; SANDBOXES+=("$h")
  if HOME="$h" "$sandbox/scripts/install.sh" alpha --skills 'nosuch-*' >"$sandbox/p4.log" 2>&1; then
    fail "$name (--skills with a pattern matching nothing should fail)"; cd "$REPO"; return
  fi
  grep -qF 'nosuch-*' "$sandbox/p4.log" || { fail "$name (error doesn't name the unmatched pattern)"; cd "$REPO"; return; }
  [ -e "$h/.alpha" ] && { fail "$name (unmatched pattern still installed something)"; cd "$REPO"; return; }

  cd "$REPO" || true
  pass "$name"
}

# ---------------------------------------------------------------------------
test_install_copy_mode() {
  local name="install/uninstall: --copy writes real files, idempotent, guards edits, removes only unmodified copies"
  local sandbox; sandbox="$(new_sandbox)"
  write_alpha_project_fixture "$sandbox"
  local fake_home; fake_home="$(mktemp_d)"; SANDBOXES+=("$fake_home")
  local proj; proj="$(new_project)"

  if ! HOME="$fake_home" "$sandbox/scripts/install.sh" alpha --project "$proj" --copy >"$sandbox/c1.log" 2>&1; then
    fail "$name (install --copy exited nonzero)"; cat "$sandbox/c1.log"; return
  fi
  local skill="$proj/.alpha/skills/widget" gadget="$proj/.alpha/skills/gadget"
  [ -d "$skill" ] && [ ! -L "$skill" ] || { fail "$name (skill not a real dir)"; return; }
  [ -f "$proj/.alpha/agents/helper.md" ] && [ ! -L "$proj/.alpha/agents/helper.md" ] || { fail "$name (agent not a real file)"; return; }
  [ -f "$proj/.alpha/output-styles/sample-style.md" ] && [ ! -L "$proj/.alpha/output-styles/sample-style.md" ] || { fail "$name (style not a real file)"; return; }
  grep -qx 'widget body.' "$skill/SKILL.md" || { fail "$name (copied skill content wrong)"; return; }

  if ! HOME="$fake_home" "$sandbox/scripts/install.sh" alpha --project "$proj" --copy >"$sandbox/c2.log" 2>&1; then
    fail "$name (re-install --copy exited nonzero)"; cat "$sandbox/c2.log"; return
  fi
  [ -n "$(find "$proj/.alpha" -name '*.bak*')" ] && { fail "$name (re-install of identical copy made a backup)"; return; }

  echo "local edit" >>"$skill/SKILL.md"
  if HOME="$fake_home" "$sandbox/scripts/install.sh" alpha --project "$proj" --copy >"$sandbox/c3.log" 2>&1; then
    fail "$name (re-install over an edited copy should refuse without --force)"; return
  fi
  grep -q 'local edit' "$skill/SKILL.md" || { fail "$name (edited copy clobbered without --force)"; return; }
  if ! HOME="$fake_home" "$sandbox/scripts/install.sh" alpha --project "$proj" --copy --force >"$sandbox/c4.log" 2>&1; then
    fail "$name (install --copy --force exited nonzero)"; cat "$sandbox/c4.log"; return
  fi
  grep -q 'local edit' "$skill/SKILL.md" && { fail "$name (--force didn't replace the edited copy)"; return; }
  grep -q 'local edit' "$proj/.alpha/skills/widget.bak/SKILL.md" 2>/dev/null || { fail "$name (--force didn't back up the edited copy)"; return; }

  echo "local edit" >>"$gadget/SKILL.md"
  if ! HOME="$fake_home" "$sandbox/scripts/uninstall.sh" alpha --project "$proj" --copy >"$sandbox/u1.log" 2>&1; then
    fail "$name (uninstall --copy exited nonzero)"; cat "$sandbox/u1.log"; return
  fi
  [ -e "$skill" ] && { fail "$name (unmodified copy not removed)"; return; }
  [ -e "$proj/.alpha/agents/helper.md" ] && { fail "$name (unmodified agent copy not removed)"; return; }
  [ -e "$proj/.alpha/output-styles/sample-style.md" ] && { fail "$name (unmodified style copy not removed)"; return; }
  grep -q 'local edit' "$gadget/SKILL.md" 2>/dev/null || { fail "$name (modified copy removed)"; return; }
  grep -q 'kept modified copy' "$sandbox/u1.log" || { fail "$name (kept copy not reported)"; return; }

  pass "$name"
}

# ---------------------------------------------------------------------------
# Sandbox for the scripts bundled with the autofix-pr-local skill: a throwaway
# git repo (they keep state in the git dir) plus a mock `gh` on $PATH that
# answers from fixture files, so no test touches the network or a real PR.
new_gh_sandbox() {
  local d
  d="$(mktemp_d)"
  SANDBOXES+=("$d")
  mkdir -p "$d/bin" "$d/fixtures" "$d/repo"
  git -C "$d/repo" init -q
  git -C "$d/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

  cat >"$d/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Mock gh. Answers from $FIXTURES; touch $FIXTURES/down to simulate an outage.
[ -f "$FIXTURES/down" ] && exit 1
args="$*"
case "$args" in
  *"-q .nameWithOwner"*) echo "owner/repo" ;;
  *"pr-review --help"*) [ -f "$FIXTURES/no-pr-review" ] && exit 1; echo "usage: gh pr-review" ;;
  *"pr-review review view"*) cat "$FIXTURES/threads.json" ;;
  *"-q .state"*) jq -r .state "$FIXTURES/view.json" ;;
  *"pr checks"*) cat "$FIXTURES/checks.json"; jq -e 'any(.bucket == "fail")' "$FIXTURES/checks.json" >/dev/null && exit 1 || exit 0 ;;
  *"pr view"*) cat "$FIXTURES/view.json" ;;
  *"api repos/"*) cat "$FIXTURES/comments.json" ;;
  *"auth status"*) echo "logged in" ;;
  *) echo "mock gh: unhandled '$args'" >&2; exit 1 ;;
esac
EOF
  chmod +x "$d/bin/gh"
  echo "$d"
}

test_pr_state_lifecycle() {
  local name="skill autofix-pr-local: pr-state.sh tracks attempts, signatures, threads"
  local d; d="$(new_gh_sandbox)"
  local st="$REPO/skills/autofix-pr-local/scripts/pr-state.sh"
  cd "$d/repo" || { fail "$name (cd failed)"; return; }

  "$st" init --pr 7 --max-attempts 2 --mode fix-local >/dev/null || { fail "$name (init failed)"; return; }
  [ -f "$d/repo/.git/autofix-pr-local/state.json" ] || { fail "$name (no state file)"; return; }

  # init is missing a required flag -> refuse
  if "$st" init --pr 7 --mode fix-local >/dev/null 2>&1; then
    fail "$name (init accepted a missing --max-attempts)"; return
  fi

  "$st" attempt >/dev/null || { fail "$name (attempt 1 rejected)"; return; }
  "$st" attempt >/dev/null || { fail "$name (attempt 2 rejected)"; return; }
  if "$st" attempt >/dev/null 2>&1; then
    fail "$name (attempt 3 should exhaust the budget)"; return
  fi

  # A new signature is progress; the same one again is not (exit 3).
  "$st" signature build "step=test: assertion failed" >/dev/null || { fail "$name (first signature rejected)"; return; }
  "$st" signature build "step=test: something else" >/dev/null || { fail "$name (changed signature rejected)"; return; }
  "$st" signature build "step=test: something else" >/dev/null 2>&1
  if [ "$?" -ne 3 ]; then
    fail "$name (repeated signature should exit 3)"; return
  fi
  jq -e '.stalled_checks | index("build")' "$d/repo/.git/autofix-pr-local/state.json" >/dev/null \
    || { fail "$name (repeated signature should mark the check stalled)"; return; }

  if "$st" thread-seen T1 >/dev/null 2>&1; then
    fail "$name (unknown thread reported as handled)"; return
  fi
  "$st" thread-done T1 >/dev/null
  "$st" thread-done T1 >/dev/null   # idempotent
  "$st" thread-seen T1 >/dev/null || { fail "$name (handled thread not remembered)"; return; }
  [ "$(jq -r '.handled_threads | length' "$d/repo/.git/autofix-pr-local/state.json")" = "1" ] \
    || { fail "$name (thread-done should de-duplicate)"; return; }

  "$st" commit abc123 "fix build" >/dev/null
  [ "$(jq -r '.commits[0].sha' "$d/repo/.git/autofix-pr-local/state.json")" = "abc123" ] \
    || { fail "$name (commit not recorded)"; return; }

  # Re-init on the same PR resumes rather than resetting the tally.
  "$st" init --pr 7 --max-attempts 5 --mode fix-push >/dev/null
  [ "$(jq -r '.attempts_used' "$d/repo/.git/autofix-pr-local/state.json")" = "2" ] \
    || { fail "$name (re-init on same PR should keep attempts_used)"; return; }
  # A different PR starts clean.
  "$st" init --pr 8 --max-attempts 5 --mode fix-push >/dev/null
  [ "$(jq -r '.attempts_used' "$d/repo/.git/autofix-pr-local/state.json")" = "0" ] \
    || { fail "$name (new PR should reset attempts_used)"; return; }

  cd "$REPO" || true
  pass "$name"
}

test_poll_pr_reports_only_changes() {
  local name="skill autofix-pr-local: poll-pr.sh reports deltas and ignores API outages"
  local d; d="$(new_gh_sandbox)"
  local poll="$REPO/skills/autofix-pr-local/scripts/poll-pr.sh"
  export FIXTURES="$d/fixtures"
  cd "$d/repo" || { fail "$name (cd failed)"; return; }

  echo '[{"name":"build","bucket":"pending"},{"name":"lint","bucket":"pass"}]' >"$FIXTURES/checks.json"
  echo '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviews":[],"comments":[]}' >"$FIXTURES/view.json"

  local out
  out="$(PATH="$d/bin:$PATH" "$poll" --pr 1 --once)"
  grep -q "check lint: pass" <<<"$out" || { fail "$name (first tick should report current state)"; return; }
  grep -q "check build" <<<"$out" && { fail "$name (pending check should not be reported)"; return; }

  out="$(PATH="$d/bin:$PATH" "$poll" --pr 1 --once)"
  [ -z "$out" ] || { fail "$name (unchanged state should be silent, got: $out)"; return; }

  # An API outage is not an event, and must not corrupt the snapshot.
  touch "$FIXTURES/down"
  out="$(PATH="$d/bin:$PATH" "$poll" --pr 1 --once)"
  [ -z "$out" ] || { fail "$name (outage should be silent, got: $out)"; return; }
  rm "$FIXTURES/down"
  out="$(PATH="$d/bin:$PATH" "$poll" --pr 1 --once)"
  [ -z "$out" ] || { fail "$name (snapshot corrupted by outage, got: $out)"; return; }

  # A failing check and a new comment are each one line, and only once.
  echo '[{"name":"build","bucket":"fail"},{"name":"lint","bucket":"pass"}]' >"$FIXTURES/checks.json"
  echo '{"state":"OPEN","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviews":[],"comments":[{"id":1}]}' >"$FIXTURES/view.json"
  out="$(PATH="$d/bin:$PATH" "$poll" --pr 1 --once)"
  grep -q "check build: fail" <<<"$out" || { fail "$name (failure not reported)"; return; }
  grep -q "comments: 1" <<<"$out" || { fail "$name (new comment not reported)"; return; }
  grep -q "check lint" <<<"$out" && { fail "$name (unchanged check re-reported)"; return; }

  # A closed PR is a terminal event, so the unbounded loop must exit on its own.
  echo '{"state":"CLOSED","mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviews":[],"comments":[]}' >"$FIXTURES/view.json"
  if ! run_with_timeout 20 env PATH="$d/bin:$PATH" "$poll" --pr 1 --interval 1 >/dev/null 2>&1; then
    fail "$name (loop should exit when the PR closes)"; return
  fi

  cd "$REPO" || true
  unset FIXTURES
  pass "$name"
}

test_pr_signals_shape() {
  local name="skill autofix-pr-local: pr-signals.sh normalises checks, threads and bots"
  local d; d="$(new_gh_sandbox)"
  local sig="$REPO/skills/autofix-pr-local/scripts/pr-signals.sh"
  export FIXTURES="$d/fixtures"
  cd "$d/repo" || { fail "$name (cd failed)"; return; }

  cat >"$FIXTURES/checks.json" <<'EOF'
[{"name":"build","bucket":"fail","link":"https://github.com/owner/repo/actions/runs/4242/job/9","workflow":"CI"},
 {"name":"deploy","bucket":"pending","link":"https://github.com/owner/repo/actions/runs/4243/job/1","workflow":"CI"},
 {"name":"circleci","bucket":"fail","link":"https://circleci.com/gh/owner/repo/77","workflow":null}]
EOF
  cat >"$FIXTURES/view.json" <<'EOF'
{"number":12,"state":"OPEN","baseRefName":"main","headRefName":"feat","url":"https://github.com/owner/repo/pull/12",
 "isDraft":false,"mergeable":"CONFLICTING","mergeStateStatus":"DIRTY","reviews":[],"comments":[]}
EOF
  # Two adjacent arrays, not one: that is what `gh api --paginate` emits per its
  # documented contract, and it must survive the collector without a 3 MB fixture.
  cat >"$FIXTURES/comments.json" <<'EOF'
[{"id":1,"user":{"login":"coderabbitai[bot]","type":"Bot"},"path":"a.py","body":"nit"}]
[{"id":2,"user":{"login":"alice","type":"User"},"path":"b.py","body":"please rename"}]
EOF
  cat >"$FIXTURES/threads.json" <<'EOF'
{"reviews":[{"comments":[
  {"thread_id":"T1","path":"a.py","line":3,"author_login":"coderabbitai[bot]","body":"nit","is_resolved":false},
  {"thread_id":"T2","path":"b.py","line":9,"author_login":"alice","body":"please rename","is_resolved":false},
  {"thread_id":"T3","path":"c.py","line":1,"author_login":"alice","body":"done","is_resolved":true}
]}]}
EOF

  local out
  out="$(PATH="$d/bin:$PATH" "$sig" --pr 12)" || { fail "$name (pr-signals.sh exited nonzero)"; return; }
  jq -e . >/dev/null 2>&1 <<<"$out" || { fail "$name (output is not JSON)"; return; }

  local check
  check="$(jq -r '[.needsBaseSync, (.counts.failing|tostring), (.counts.unresolvedThreads|tostring),
                   (.counts.botThreads|tostring), (.counts.humanThreads|tostring),
                   (.failingChecks[0].runId|tostring), (.checks[2].isActions|tostring),
                   (.havePrReview|tostring)] | join(",")' <<<"$out")"
  if [ "$check" != "true,2,2,1,1,4242,false,true" ]; then
    fail "$name (unexpected shape: $check)"; return
  fi
  jq -e '.reviewComments | map(select(.isBot)) | length == 1' >/dev/null <<<"$out" \
    || { fail "$name (bot classification of review comments wrong)"; return; }
  # gh pr-review names this field author_login. Reading the wrong name silently
  # yielded login "unknown" and isBot false for every thread, so botThreads was
  # always 0 and the bots/reviews triggers could not tell them apart.
  jq -e '[.unresolvedThreads[].login] == ["coderabbitai[bot]", "alice"]' >/dev/null <<<"$out" \
    || { fail "$name (thread authors not resolved: $(jq -c '[.unresolvedThreads[].login]' <<<"$out"))"; return; }

  # Without the extension, threads are empty but everything else still works.
  touch "$FIXTURES/no-pr-review"
  out="$(PATH="$d/bin:$PATH" "$sig" --pr 12)" || { fail "$name (failed without gh-pr-review)"; return; }
  check="$(jq -r '[(.havePrReview|tostring), (.counts.unresolvedThreads|tostring), (.counts.failing|tostring)] | join(",")' <<<"$out")"
  [ "$check" = "false,0,2" ] || { fail "$name (degraded mode wrong: $check)"; return; }

  cd "$REPO" || true
  unset FIXTURES
  pass "$name"
}

test_pr_signals_past_argv_cap() {
  local name="skill autofix-pr-local: pr-signals.sh survives a review-comment payload past the argv cap"
  local d; d="$(new_gh_sandbox)"
  local sig="$REPO/skills/autofix-pr-local/scripts/pr-signals.sh"
  export FIXTURES="$d/fixtures"
  cd "$d/repo" || { fail "$name (cd failed)"; return; }

  echo '[{"name":"build","bucket":"fail","link":"https://github.com/owner/repo/actions/runs/4242/job/9","workflow":"CI"}]' >"$FIXTURES/checks.json"
  cat >"$FIXTURES/view.json" <<'EOF'
{"number":12,"state":"OPEN","baseRefName":"main","headRefName":"feat","url":"https://github.com/owner/repo/pull/12",
 "isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviews":[],"comments":[]}
EOF
  echo '{"reviews":[]}' >"$FIXTURES/threads.json"

  # Two arrays of 1500 comments with 1 KB bodies: ~3 MB. That is past
  # MAX_ARG_STRLEN (131072, the per-argument kernel cap that broke the old
  # --argjson call) *and* past ARG_MAX (~2 MB), so no argv transport can carry
  # it -- including one that split the payload across several arguments. Two
  # documents also pin the `gh api --paginate` stream shape, which `add`
  # concatenates and a bare `[0]` would silently truncate to the first page.
  jq -nc '[range(0;1500)    | {id: ., user: {login: "alice",    type: "User"}, path: "a.py", body: ("x" * 1024)}]'  >"$FIXTURES/comments.json"
  jq -nc '[range(1500;3000) | {id: ., user: {login: "bot[bot]", type: "Bot"},  path: "b.py", body: ("y" * 1024)}]' >>"$FIXTURES/comments.json"

  local bytes; bytes="$(wc -c <"$FIXTURES/comments.json")"
  if [ "$bytes" -le 131072 ]; then
    fail "$name (fixture is only $bytes bytes, no longer past MAX_ARG_STRLEN: it proves nothing)"; return
  fi

  local out
  out="$(PATH="$d/bin:$PATH" "$sig" --pr 12)" \
    || { fail "$name (exited nonzero on a $bytes-byte payload)"; return; }
  jq -e . >/dev/null 2>&1 <<<"$out" || { fail "$name (output is not JSON)"; return; }

  # Every comment from both pages survives, bots are still classified, and the
  # 400-char truncation still runs.
  local check
  check="$(jq -r '[(.reviewComments | length | tostring),
                   (.reviewComments | map(select(.isBot)) | length | tostring),
                   (.reviewComments | map(.body | length) | max | tostring),
                   (.counts.failing | tostring)] | join(",")' <<<"$out")"
  if [ "$check" != "3000,1500,400,1" ]; then
    fail "$name (large payload mangled: $check)"; return
  fi

  # Size-independence is a property of the transport, not of this fixture: a
  # payload that grows with the PR must never be an argv argument again.
  if grep -qE -- '--argjson (checks|comments|threads) ' "$sig"; then
    fail "$name (a growable payload is back in argv)"; return
  fi

  cd "$REPO" || true
  unset FIXTURES
  pass "$name"
}

# ---------------------------------------------------------------------------
# Sandbox for the script bundled with the grill-for-pr skill: a throwaway git
# repo with a main branch and a feature branch whose diff covers every file kind
# the script classifies, plus a mock `gh` answering the PR/issue/review-comment
# calls from fixtures. Prints the sandbox path; the caller uses $d/repo as cwd.
new_recon_sandbox() {
  local d
  d="$(mktemp_d)"
  SANDBOXES+=("$d")
  mkdir -p "$d/bin" "$d/fixtures" "$d/repo"
  local g="git -C $d/repo -c user.email=t@t -c user.name=t"

  $g init -q -b main
  mkdir -p "$d/repo/src" "$d/repo/tests" "$d/repo/migrations" "$d/repo/.github/workflows"
  echo "a" >"$d/repo/src/auth.py"
  echo "b" >"$d/repo/src/old_name.py"
  echo "l" >"$d/repo/package-lock.json"
  echo "t" >"$d/repo/tests/test_auth.py"
  echo "m" >"$d/repo/migrations/001_init.sql"
  echo "c" >"$d/repo/.github/workflows/ci.yml"
  echo "d" >"$d/repo/README.md"
  printf '## What\n## Why\n' >"$d/repo/.github/pull_request_template.md"
  printf '/src/ @alice\n*.sql @bob @db-team\n' >"$d/repo/.github/CODEOWNERS"
  $g add -A >/dev/null; $g commit -qm init

  $g checkout -qb feat
  printf 'a\nchanged\nmore\n' >"$d/repo/src/auth.py"
  $g mv src/old_name.py src/new_name.py
  printf 'l\nlock churn\n' >"$d/repo/package-lock.json"
  printf 't\nnew test\n' >"$d/repo/tests/test_auth.py"
  printf 'm\nALTER TABLE x;\n' >"$d/repo/migrations/001_init.sql"
  $g add -A >/dev/null; $g commit -qm "fix truncation (#42)"

  cat >"$d/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Mock gh. Answers from $FIXTURES; touch $FIXTURES/down to simulate no auth.
[ -f "$FIXTURES/down" ] && exit 1
args="$*"
case "$args" in
  *"auth status"*) echo "logged in" ;;
  *"-q .nameWithOwner"*) echo "owner/repo" ;;
  *"-q .defaultBranchRef.name"*) echo "main" ;;
  *"pr view"*) [ -f "$FIXTURES/view.json" ] || exit 1; cat "$FIXTURES/view.json" ;;
  *"pr list"*) cat "$FIXTURES/merged.json" ;;
  *"issue view"*) cat "$FIXTURES/issue.json" ;;
  *"pulls/comments"*) cat "$FIXTURES/review-comments.json" ;;
  *) echo "mock gh: unhandled '$args'" >&2; exit 1 ;;
esac
EOF
  chmod +x "$d/bin/gh"
  echo "$d"
}

test_pr_recon_shape() {
  local name="skill grill-for-pr: pr-recon.sh classifies the diff and profiles reviewers"
  local d; d="$(new_recon_sandbox)"
  local recon="$REPO/skills/grill-for-pr/scripts/pr-recon.sh"
  export FIXTURES="$d/fixtures"
  cd "$d/repo" || { fail "$name (cd failed)"; return; }

  cat >"$FIXTURES/merged.json" <<'EOF'
[{"number":9,"title":"Earlier PR","body":"house style","author":{"login":"alice"},
  "reviews":[{"author":{"login":"dana"}},{"author":{"login":"coderabbitai[bot]"}}]}]
EOF
  cat >"$FIXTURES/issue.json" <<'EOF'
{"number":42,"title":"CSV export truncates","state":"OPEN","labels":[{"name":"bug"}],"body":"silently stops at 10k"}
EOF
  cat >"$FIXTURES/review-comments.json" <<'EOF'
[{"user":{"login":"dana","type":"User"},"path":"src/auth.py","body":"how much memory does this hold?"},
 {"user":{"login":"coderabbitai[bot]","type":"Bot"},"path":"src/auth.py","body":"nit"},
 {"user":{"login":"stranger","type":"User"},"path":"other.py","body":"unrelated"}]
EOF

  local out
  out="$(PATH="$d/bin:$PATH" "$recon" --base main)" || { fail "$name (exited nonzero)"; return; }
  jq -e . >/dev/null 2>&1 <<<"$out" || { fail "$name (output is not JSON)"; return; }

  local check
  check="$(jq -r '[(.diff.files|tostring), (.diff.byKind.code|tostring), (.diff.byKind.lockfile|tostring),
                   (.diff.touchesMigrations|tostring), (.diff.hasTests|tostring),
                   (.diff.pureRenames|length|tostring), (.issue.number|tostring),
                   (.conventions.prTemplatePath)] | join(",")' <<<"$out")"
  if [ "$check" != "5,2,1,true,true,1,42,.github/pull_request_template.md" ]; then
    fail "$name (unexpected shape: $check)"; return
  fi

  # A pure rename is noise, not something to read; a lockfile likewise.
  jq -e '(.diff.substantive | index("src/new_name.py")) == null
         and (.diff.mechanical | index("src/new_name.py")) != null
         and (.diff.mechanical | index("package-lock.json")) != null' >/dev/null <<<"$out" \
    || { fail "$name (rename/lockfile not classified as mechanical)"; return; }
  jq -e '.diff.substantive[0] == "src/auth.py"' >/dev/null <<<"$out" \
    || { fail "$name (substantive files should lead with the biggest churn)"; return; }
  jq -e '.issueRefs | index("#42")' >/dev/null <<<"$out" \
    || { fail "$name (issue reference not found in the commit subject)"; return; }

  # CODEOWNERS matches on the changed paths, and review comments narrow to the
  # people who might actually review this — bots and strangers dropped.
  jq -e '(.reviewers.codeowners | index("@alice")) and (.reviewers.codeowners | index("@bob"))
         and (.reviewers.candidates | index("dana"))
         and (.reviewers.recentReviewComments | length) == 1
         and .reviewers.recentReviewComments[0].login == "dana"' >/dev/null <<<"$out" \
    || { fail "$name (reviewer profile wrong: $(jq -c .reviewers <<<"$out"))"; return; }

  # No open PR on this branch is the normal pre-creation case, not an error.
  jq -e '.pr == null and (.notes | length) > 0' >/dev/null <<<"$out" \
    || { fail "$name (a missing PR should be a note, not a failure)"; return; }

  # --no-profile skips the whole audience half.
  out="$(PATH="$d/bin:$PATH" "$recon" --base main --no-profile)" || { fail "$name (--no-profile failed)"; return; }
  jq -e '.reviewers == {"profiled": false}' >/dev/null <<<"$out" \
    || { fail "$name (--no-profile still profiled)"; return; }

  # Without a usable gh, the local facts still land and the gap is a note.
  touch "$FIXTURES/down"
  out="$(PATH="$d/bin:$PATH" "$recon" --base main)" || { fail "$name (failed without gh)"; return; }
  check="$(jq -r '[(.haveGh|tostring), (.diff.files|tostring), (.pr|tostring),
                   ((.notes | map(select(test("gh is missing"))) | length)|tostring)] | join(",")' <<<"$out")"
  [ "$check" = "false,5,null,1" ] || { fail "$name (degraded mode wrong: $check)"; return; }
  rm "$FIXTURES/down"

  # A dirty worktree is reported, so the skill can say what will not be in the PR.
  echo "scratch" >"$d/repo/notes.txt"
  out="$(PATH="$d/bin:$PATH" "$recon" --base main)"
  jq -e '.worktree.dirty and .worktree.untracked == 1' >/dev/null <<<"$out" \
    || { fail "$name (uncommitted work not reported)"; return; }

  cd "$REPO" || true
  unset FIXTURES
  pass "$name"
}

test_pr_recon_past_argv_cap() {
  local name="skill grill-for-pr: pr-recon.sh survives a PR body past the argv cap"
  local d; d="$(new_recon_sandbox)"
  local recon="$REPO/skills/grill-for-pr/scripts/pr-recon.sh"
  export FIXTURES="$d/fixtures"
  cd "$d/repo" || { fail "$name (cd failed)"; return; }

  echo '[]' >"$FIXTURES/merged.json"
  echo '[]' >"$FIXTURES/review-comments.json"
  echo '{"number":42,"title":"t","state":"OPEN","labels":[],"body":"b"}' >"$FIXTURES/issue.json"

  # pr-recon.sh never truncates the PR body, so the body is the real argv load.
  # 300000 chars is past MAX_ARG_STRLEN (131072), the per-argument kernel cap, so
  # the old `--argjson pr` could not exec jq at all.
  jq -nc '{number:5,url:"u",state:"OPEN",isDraft:false,title:"t",body:("x"*300000),
           baseRefName:"main",headRefName:"feat",author:{login:"me"},
           reviewRequests:[],additions:1,deletions:1,changedFiles:1}' >"$FIXTURES/view.json"

  local bytes; bytes="$(wc -c <"$FIXTURES/view.json")"
  if [ "$bytes" -le 131072 ]; then
    fail "$name (fixture is only $bytes bytes, no longer past MAX_ARG_STRLEN: it proves nothing)"; return
  fi

  local out
  out="$(PATH="$d/bin:$PATH" "$recon" --base main)" \
    || { fail "$name (exited nonzero on a $bytes-byte PR body)"; return; }
  jq -e . >/dev/null 2>&1 <<<"$out" || { fail "$name (output is not JSON)"; return; }
  jq -e '(.pr.body | length) == 300000' >/dev/null <<<"$out" \
    || { fail "$name (PR body did not survive intact)"; return; }
  # The diff and codeowners unwraps ride the same change, so pin them here too.
  jq -e '(.diff.byFile | length) > 0 and (.reviewers.codeowners | length) > 0' >/dev/null <<<"$out" \
    || { fail "$name (diff or codeowners lost in the slurpfile unwrap)"; return; }

  cd "$REPO" || true
  unset FIXTURES
  pass "$name"
}

test_zotero_local_cli() {
  local name="skill zotero-local: zotero.py against a mock local API"
  local out
  if ! command -v python3 >/dev/null 2>&1; then
    fail "$name (python3 not found)"; return
  fi
  # -I: ignore PYTHON* env vars and keep cwd off sys.path.
  out="$(python3 -I "$REPO/scripts/test_zotero_local.py" 2>&1)" \
    || { echo "$out"; fail "$name"; return; }
  pass "$name"
}

# ---------------------------------------------------------------------------
test_splice_and_passthrough
test_harnesses_targeting
test_variant_headers
test_lint_name_dir_mismatch
test_lint_duplicate_key
test_lint_missing_header_for_targeted_harness
test_install_uninstall_idempotent
test_install_guardrail_and_force
test_install_dry_run
test_install_claude_md_symlink
test_install_claude_md_guardrail_and_force
test_install_output_styles_symlink
test_install_output_styles_prune_stale
test_install_project_requires_root
test_install_project_symlinks_and_uninstall
test_install_skill_selectors
test_install_skill_patterns
test_install_copy_mode
test_pr_state_lifecycle
test_poll_pr_reports_only_changes
test_pr_signals_shape
test_pr_signals_past_argv_cap
test_pr_recon_shape
test_pr_recon_past_argv_cap
test_zotero_local_cli

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$FAILURES test(s) failed."
  exit 1
fi
