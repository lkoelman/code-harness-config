#!/usr/bin/env bash
# Tests for scripts/build.sh, install.sh, uninstall.sh, and the scripts bundled
# with the autofix-pr-local skill.
# Each test runs against a throwaway sandbox copy of the scripts plus
# fixture skills/agents/harnesses, so nothing here touches the real
# skills/ or agents/ tree or the real $HOME. The skill-script tests add a
# throwaway git repo and a mock `gh` on $PATH, so they never hit the network.
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
# Sandbox for the scripts bundled with the autofix-pr-local skill: a throwaway
# git repo (they keep state in the git dir) plus a mock `gh` on $PATH that
# answers from fixture files, so no test touches the network or a real PR.
new_gh_sandbox() {
  local d
  d="$(mktemp -d)"
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
  if ! PATH="$d/bin:$PATH" timeout 20 "$poll" --pr 1 --interval 1 >/dev/null 2>&1; then
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
  cat >"$FIXTURES/comments.json" <<'EOF'
[{"id":1,"user":{"login":"coderabbitai[bot]","type":"Bot"},"path":"a.py","body":"nit"},
 {"id":2,"user":{"login":"alice","type":"User"},"path":"b.py","body":"please rename"}]
EOF
  cat >"$FIXTURES/threads.json" <<'EOF'
{"reviews":[{"comments":[
  {"thread_id":"T1","path":"a.py","line":3,"author":"coderabbitai[bot]","body":"nit","is_resolved":false},
  {"thread_id":"T2","path":"b.py","line":9,"author":"alice","body":"please rename","is_resolved":false},
  {"thread_id":"T3","path":"c.py","line":1,"author":"alice","body":"done","is_resolved":true}
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

  # Without the extension, threads are empty but everything else still works.
  touch "$FIXTURES/no-pr-review"
  out="$(PATH="$d/bin:$PATH" "$sig" --pr 12)" || { fail "$name (failed without gh-pr-review)"; return; }
  check="$(jq -r '[(.havePrReview|tostring), (.counts.unresolvedThreads|tostring), (.counts.failing|tostring)] | join(",")' <<<"$out")"
  [ "$check" = "false,0,2" ] || { fail "$name (degraded mode wrong: $check)"; return; }

  cd "$REPO" || true
  unset FIXTURES
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
test_pr_state_lifecycle
test_poll_pr_reports_only_changes
test_pr_signals_shape

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$FAILURES test(s) failed."
  exit 1
fi
