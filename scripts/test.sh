#!/usr/bin/env bash
# Tests for scripts/build.sh, install.sh, uninstall.sh.
# Each test runs against a throwaway sandbox copy of the scripts plus
# fixture skills/agents/harnesses, so nothing here touches the real
# skills/ or agents/ tree or the real $HOME.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
FAILURES=0
SANDBOXES=()

pass() { echo "ok - $1"; }
fail() { echo "FAIL - $1"; FAILURES=$((FAILURES + 1)); }

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
  d="$(mktemp -d)"
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

  local fake_home; fake_home="$(mktemp -d)"; SANDBOXES+=("$fake_home")

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

  local fake_home; fake_home="$(mktemp -d)"; SANDBOXES+=("$fake_home")
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

  local fake_home; fake_home="$(mktemp -d)"; SANDBOXES+=("$fake_home")

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
test_splice_and_passthrough
test_harnesses_targeting
test_variant_headers
test_lint_name_dir_mismatch
test_lint_duplicate_key
test_lint_missing_header_for_targeted_harness
test_install_uninstall_idempotent
test_install_guardrail_and_force
test_install_dry_run

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$FAILURES test(s) failed."
  exit 1
fi
