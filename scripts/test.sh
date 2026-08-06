#!/usr/bin/env bash
# Tests for scripts/build.sh, install.sh, uninstall.sh, and the scripts bundled
# with the autofix-pr-local and ssh-teleport skills.
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
# Sandbox for the scripts bundled with the ssh-teleport skill: a throwaway $HOME
# holding one fake Claude Code session (transcript, subagent transcript, tool
# result, file history, tasks, plan file) plus a throwaway git repo with an
# origin remote. Nothing here reaches the network or the real ~/.claude.
# Prints the sandbox path; the caller uses $d/home as HOME and $d/repo as cwd.
new_teleport_sandbox() {
  local d
  d="$(mktemp -d)"
  SANDBOXES+=("$d")

  local sid="11111111-2222-3333-4444-555555555555"
  local src="$d/repo"
  local enc
  enc="$(printf '%s' "$src" | sed 's/[^a-zA-Z0-9]/-/g')"
  local cc="$d/home/.claude"

  mkdir -p "$src" "$cc/projects/$enc/$sid/subagents" "$cc/projects/$enc/$sid/tool-results" \
           "$cc/file-history/$sid" "$cc/tasks/$sid" "$cc/session-env/$sid" "$cc/plans"

  git -C "$src" init -q
  git -C "$src" remote add origin git@github.com:owner/repo.git
  echo "tracked" >"$src/tracked.txt"
  git -C "$src" add tracked.txt
  git -C "$src" -c user.email=t@t -c user.name=t commit -q -m init

  # A transcript carrying every path-bearing field the rewrite has to reach.
  # trackedFileBackups deliberately mixes a relative key (in-repo, must survive
  # untouched) with an absolute one (out-of-repo, must be rewritten).
  cat >"$cc/projects/$enc/$sid.jsonl" <<EOF
{"type":"mode","mode":"normal","sessionId":"$sid"}
{"type":"file-history-snapshot","messageId":"m1","snapshot":{"messageId":"m1","trackedFileBackups":{"tracked.txt":{"realParentDir":"$src","backupFileName":"aaaaaaaaaaaaaaaa@v1"},"$d/home/.claude/plans/teleport-fixture.md":{"realParentDir":"$d/home/.claude/plans","backupFileName":"bbbbbbbbbbbbbbbb@v1"}}},"isSnapshotUpdate":false}
{"parentUuid":null,"isSidechain":false,"type":"user","uuid":"u-1","timestamp":"2026-08-05T18:05:57.952Z","message":{"role":"user","content":"look at $src/tracked.txt"},"userType":"external","entrypoint":"cli","cwd":"$src","sessionId":"$sid","session_id":"$sid","version":"2.1.222","gitBranch":"main","slug":"teleport-fixture"}
{"parentUuid":"u-1","isSidechain":false,"type":"assistant","uuid":"a-1","timestamp":"2026-08-05T18:06:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_x","name":"Read","input":{"file_path":"$src/tracked.txt"}}]},"cwd":"$src","sessionId":"$sid","version":"2.1.222","gitBranch":"main"}
{"type":"file-history-delta","messageId":"m2","snapshotMessageId":"m1","trackingPath":"tracked.txt","backup":{"backupFileName":"aaaaaaaaaaaaaaaa@v1","version":1,"realParentDir":"$src"},"timestamp":"2026-08-05T18:06:01.000Z"}
{"parentUuid":"a-1","isSidechain":false,"type":"attachment","uuid":"at-1","timestamp":"2026-08-05T18:06:02.000Z","attachment":{"type":"plan_mode","planFilePath":"$d/home/.claude/plans/teleport-fixture.md"},"cwd":"$src","sessionId":"$sid","version":"2.1.222","gitBranch":"main"}
{"type":"last-prompt","lastPrompt":"look at $src/tracked.txt","leafUuid":"at-1","sessionId":"$sid"}
EOF

  cat >"$cc/projects/$enc/$sid/subagents/agent-abc.jsonl" <<EOF
{"parentUuid":null,"type":"user","uuid":"s-1","message":{"role":"user","content":"explore $src"},"cwd":"$src","sessionId":"$sid","gitBranch":"main"}
EOF
  echo '{"agentType":"Explore","description":"fixture","toolUseId":"toolu_x","spawnDepth":1}' \
    >"$cc/projects/$enc/$sid/subagents/agent-abc.meta.json"
  echo "a saved tool result mentioning $src" >"$cc/projects/$enc/$sid/tool-results/toolu_x.txt"

  echo "pre-edit contents" >"$cc/file-history/$sid/aaaaaaaaaaaaaaaa@v1"
  echo "4" >"$cc/tasks/$sid/.highwatermark"
  : >"$cc/tasks/$sid/.lock"
  echo "# fixture plan for $src" >"$cc/plans/teleport-fixture.md"
  echo "SECRET" >"$cc/.credentials.json"

  cat >"$cc/history.jsonl" <<EOF
{"display":"unrelated","pastedContents":{},"timestamp":1785226928594,"project":"/somewhere/else","sessionId":"99999999-0000-0000-0000-000000000000"}
{"display":"look at tracked.txt","pastedContents":{},"timestamp":1785953686750,"project":"$src","sessionId":"$sid"}
EOF

  echo "$d"
}

test_ssh_teleport_encodes_paths() {
  local name="skill ssh-teleport: stage-session.sh encodes target paths and refuses the ambiguous ones"
  local d; d="$(new_teleport_sandbox)"
  local stage="$REPO/skills/ssh-teleport/scripts/stage-session.sh"
  local sid="11111111-2222-3333-4444-555555555555"

  # Every non-alphanumeric becomes '-'; case is preserved; runs are not collapsed.
  local out enc
  out="$(HOME="$d/home" "$stage" --session-id "$sid" --target-cwd '/home/Bob/code/my_repo.git v2' \
          --target-home /home/Bob --target-branch main --out "$d/stage1" 2>&1)" \
    || { fail "$name (staging a plain path failed: $out)"; return; }
  enc="$(jq -r '.encodedDir' <<<"$out")"
  if [ "$enc" != "-home-Bob-code-my-repo-git-v2" ]; then
    fail "$name (encoded '$enc', expected '-home-Bob-code-my-repo-git-v2')"; return
  fi

  # Non-ASCII: Claude replaces per UTF-16 code unit, sed per byte, so refuse.
  HOME="$d/home" "$stage" --session-id "$sid" --target-cwd '/home/bob/프로젝트/app' \
    --target-home /home/bob --target-branch main --out "$d/stage2" >/dev/null 2>&1
  if [ "$?" -ne 4 ]; then
    fail "$name (a non-ASCII target path should exit 4)"; return
  fi

  # Over 200 chars: the suffix is an internal hash we cannot reproduce, so refuse.
  local long; long="/home/bob/$(printf 'a%.0s' $(seq 1 210))"
  HOME="$d/home" "$stage" --session-id "$sid" --target-cwd "$long" \
    --target-home /home/bob --target-branch main --out "$d/stage3" >/dev/null 2>&1
  if [ "$?" -ne 4 ]; then
    fail "$name (an over-200-char encoding should exit 4)"; return
  fi

  pass "$name"
}

test_ssh_teleport_rewrites_transcript() {
  local name="skill ssh-teleport: stage-session.sh rewrites paths and stages the whole session"
  local d; d="$(new_teleport_sandbox)"
  local stage="$REPO/skills/ssh-teleport/scripts/stage-session.sh"
  local sid="11111111-2222-3333-4444-555555555555"
  local src="$d/repo"
  local dst="/home/bob/worktrees-repo/feature"
  local enc="-home-bob-worktrees-repo-feature"

  local out
  out="$(HOME="$d/home" "$stage" --session-id "$sid" --target-cwd "$dst" \
          --target-home /home/bob --target-branch feature --out "$d/stage" 2>&1)" \
    || { fail "$name (stage-session.sh exited nonzero: $out)"; return; }
  jq -e . >/dev/null 2>&1 <<<"$out" || { fail "$name (manifest is not JSON)"; return; }

  local t="$d/stage/.claude/projects/$enc/$sid.jsonl"
  [ -f "$t" ] || { fail "$name (no transcript at the target-encoded path)"; return; }

  # Every line must still be valid JSON after the rewrite.
  local n=0
  while IFS= read -r line; do
    n=$((n + 1))
    jq -e . >/dev/null 2>&1 <<<"$line" || { fail "$name (line $n is not valid JSON)"; return; }
  done <"$t"

  # No trace of the source path or the source home anywhere in the transcript.
  if grep -qF "$src" "$t"; then
    fail "$name (source path survives in the transcript)"; return
  fi
  if grep -qF "$d/home" "$t"; then
    fail "$name (source home survives in the transcript)"; return
  fi

  local got
  got="$(jq -sr '[ (map(select(.cwd)) | map(.cwd) | unique | join(",")),
                   (map(select(.gitBranch)) | map(.gitBranch) | unique | join(",")),
                   (map(select(.sessionId)) | map(.sessionId) | unique | join(",")),
                   (map(select(.type == "attachment"))[0].attachment.planFilePath),
                   (map(select(.type == "file-history-delta"))[0].backup.realParentDir),
                   (map(select(.type == "file-history-delta"))[0].trackingPath),
                   (map(select(.type == "user" and .uuid == "u-1"))[0].uuid)
                 ] | join("|")' "$t")"
  local want="$dst|feature|$sid|/home/bob/.claude/plans/teleport-fixture.md|$dst|tracked.txt|u-1"
  if [ "$got" != "$want" ]; then
    fail "$name (rewrite wrong:
  got  $got
  want $want)"; return
  fi

  # trackedFileBackups: the relative in-repo key survives verbatim (its
  # file-history hash is over that relative path), the absolute one is rewritten.
  jq -se 'map(select(.type == "file-history-snapshot"))[0].snapshot.trackedFileBackups
          | has("tracked.txt") and has("/home/bob/.claude/plans/teleport-fixture.md")' \
     >/dev/null "$t" || { fail "$name (trackedFileBackups keys wrong)"; return; }

  # The resumability test in Claude Code: the file must hold a user/assistant line.
  grep -q '"type":"user"' "$t" || { fail "$name (no user line left, session would not resume)"; return; }

  # Sidecars, file history, tasks and the plan file all travel; the lock and the
  # credentials file do not.
  local f
  for f in "projects/$enc/$sid/subagents/agent-abc.jsonl" \
           "projects/$enc/$sid/subagents/agent-abc.meta.json" \
           "projects/$enc/$sid/tool-results/toolu_x.txt" \
           "file-history/$sid/aaaaaaaaaaaaaaaa@v1" \
           "tasks/$sid/.highwatermark" \
           "plans/teleport-fixture.md"; do
    [ -e "$d/stage/.claude/$f" ] || { fail "$name (did not stage $f)"; return; }
  done
  for f in "tasks/$sid/.lock" ".credentials.json"; do
    [ -e "$d/stage/.claude/$f" ] && { fail "$name (staged $f, which must never travel)"; return; }
  done

  # The subagent transcript is rewritten too.
  if grep -qF "$src" "$d/stage/.claude/projects/$enc/$sid/subagents/agent-abc.jsonl"; then
    fail "$name (source path survives in the subagent transcript)"; return
  fi

  # history.jsonl travels as a fragment holding only this session's lines.
  local frag="$d/stage/.claude/ssh-teleport/$sid.history.jsonl"
  [ -f "$frag" ] || { fail "$name (no history fragment)"; return; }
  got="$(jq -sr '[length, (.[0].sessionId), (.[0].project)] | join("|")' "$frag")"
  if [ "$got" != "1|$sid|$dst" ]; then
    fail "$name (history fragment wrong: $got)"; return
  fi

  pass "$name"
}

# Sandbox for probe-target.sh: a throwaway git repo with an origin remote plus a
# mock `ssh` on $PATH that records its argv and answers from $FIXTURES.
new_ssh_sandbox() {
  local d
  d="$(mktemp -d)"
  SANDBOXES+=("$d")
  mkdir -p "$d/bin" "$d/fixtures" "$d/repo" "$d/home"

  # Pin the branch name so the expectation below does not depend on the
  # developer's init.defaultBranch.
  git -C "$d/repo" init -q --initial-branch=main
  git -C "$d/repo" remote add origin git@github.com:owner/repo.git
  git -C "$d/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

  cat >"$d/bin/ssh" <<'EOF'
#!/usr/bin/env bash
# Mock ssh. Records argv in $FIXTURES/argv, answers `-G` from $FIXTURES/config-G
# and a remote command from $FIXTURES/probe. Touch $FIXTURES/down for an
# unreachable host.
printf '%s\n' "$*" >>"$FIXTURES/argv"
case " $* " in
  *" -G "*) cat "$FIXTURES/config-G"; exit 0 ;;
esac
[ -f "$FIXTURES/down" ] && { echo "ssh: connect to host: No route to host" >&2; exit 255; }
cat >/dev/null            # swallow the streamed script on stdin
cat "$FIXTURES/probe"
EOF
  chmod +x "$d/bin/ssh"
  echo "$d"
}

test_ssh_teleport_probe_parses_target() {
  local name="skill ssh-teleport: probe-target.sh resolves the target and forwards the agent"
  local d; d="$(new_ssh_sandbox)"
  local probe="$REPO/skills/ssh-teleport/scripts/probe-target.sh"
  export FIXTURES="$d/fixtures"
  cd "$d/repo" || { fail "$name (cd failed)"; return; }

  cat >"$FIXTURES/config-G" <<'EOF'
user remoteuser
hostname 10.0.0.9
port 22
EOF
  cat >"$FIXTURES/probe" <<'EOF'
remoteHome	/home/remoteuser
claudeVersion	2.1.222 (Claude Code)
hasJq	yes
hasRsync	yes
repoPath	/home/remoteuser/code/repo
originMatches	yes
headPresent	yes
branchCheckedOut	no
sessionLive	no
agentForwardingOk	yes
EOF

  local out
  out="$(PATH="$d/bin:$PATH" HOME="$d/home" "$probe" --host somebox 2>&1)" \
    || { fail "$name (probe-target.sh exited nonzero: $out)"; return; }
  jq -e . >/dev/null 2>&1 <<<"$out" || { fail "$name (output is not JSON: $out)"; return; }

  local got
  got="$(jq -r '[.user, .hostname, .remoteHome, .claudeVersion, (.hasJq|tostring),
                 .repoPath, (.originMatches|tostring), (.headPresent|tostring),
                 (.agentForwardingOk|tostring), .suggestedWorktreePath] | join("|")' <<<"$out")"
  local want="remoteuser|10.0.0.9|/home/remoteuser|2.1.222|true|/home/remoteuser/code/repo|true|true|true|/home/remoteuser/code/worktrees-repo/main"
  if [ "$got" != "$want" ]; then
    fail "$name (probe wrong:
  got  $got
  want $want)"; return
  fi

  # The remote round trip must forward the agent, since it is what lets the
  # target reach origin without its own key.
  grep -q -- '-A' "$FIXTURES/argv" || { fail "$name (probe did not pass -A)"; return; }

  # A refused forwarding is reported, not silently assumed to work.
  sed -i 's/^agentForwardingOk\tyes/agentForwardingOk\tno/' "$FIXTURES/probe"
  out="$(PATH="$d/bin:$PATH" HOME="$d/home" "$probe" --host somebox 2>&1)"
  jq -e '.agentForwardingOk == false' >/dev/null <<<"$out" \
    || { fail "$name (refused agent forwarding not reported)"; return; }

  # No repo found on the target -> empty repoPath, still exit 0 so the skill can ask.
  sed -i 's|^repoPath\t.*|repoPath\t|; s/^originMatches\tyes/originMatches\tno/' "$FIXTURES/probe"
  out="$(PATH="$d/bin:$PATH" HOME="$d/home" "$probe" --host somebox 2>&1)" \
    || { fail "$name (a missing target repo should not be fatal)"; return; }
  jq -e '.repoPath == "" and .originMatches == false' >/dev/null <<<"$out" \
    || { fail "$name (missing repo not reported)"; return; }

  # Missing remote dependency -> exit 3.
  sed -i 's/^hasJq\tyes/hasJq\tno/' "$FIXTURES/probe"
  PATH="$d/bin:$PATH" HOME="$d/home" "$probe" --host somebox >/dev/null 2>&1
  [ "$?" -eq 3 ] || { fail "$name (a target without jq should exit 3)"; return; }

  # --summary teleports never touch claude or jq on the target, so --require
  # narrows what is mandatory: missing jq is fine, missing rsync still isn't.
  PATH="$d/bin:$PATH" HOME="$d/home" "$probe" --host somebox --require rsync >/dev/null 2>&1
  [ "$?" -eq 0 ] || { fail "$name (--require rsync should ignore a missing jq)"; return; }
  sed -i 's/^hasRsync\tyes/hasRsync\tno/' "$FIXTURES/probe"
  PATH="$d/bin:$PATH" HOME="$d/home" "$probe" --host somebox --require rsync >/dev/null 2>&1
  [ "$?" -eq 3 ] || { fail "$name (--require rsync should still exit 3 on a missing rsync)"; return; }
  sed -i 's/^hasRsync\tno/hasRsync\tyes/' "$FIXTURES/probe"

  # Unreachable host -> exit 2.
  touch "$FIXTURES/down"
  PATH="$d/bin:$PATH" HOME="$d/home" "$probe" --host somebox >/dev/null 2>&1
  [ "$?" -eq 2 ] || { fail "$name (an unreachable host should exit 2)"; return; }

  cd "$REPO" || true
  unset FIXTURES
  pass "$name"
}

test_ssh_teleport_remote_setup_worktree() {
  local name="skill ssh-teleport: remote-setup.sh adds the worktree and registers the path"
  local d; d="$(mktemp -d)"; SANDBOXES+=("$d")
  local rs="$REPO/skills/ssh-teleport/scripts/remote-setup.sh"
  local sid="11111111-2222-3333-4444-555555555555"

  mkdir -p "$d/home"
  git -C "$d" init -q --initial-branch=main repo >/dev/null 2>&1 || {
    mkdir -p "$d/repo"; git -C "$d/repo" init -q; }
  git -C "$d/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  local sha; sha="$(git -C "$d/repo" rev-parse HEAD)"
  local branch; branch="$(git -C "$d/repo" branch --show-current)"

  # The session's own branch name is taken (it is checked out in the main
  # worktree), so the fallback name must be used.
  local out
  out="$(HOME="$d/home" "$rs" worktree --repo "$d/repo" --path "$d/wt" \
          --branch "$branch" --commit "$sha" --suffix 1111 2>&1)" \
    || { fail "$name (worktree add failed: $out)"; return; }
  jq -e . >/dev/null 2>&1 <<<"$out" || { fail "$name (worktree output is not JSON: $out)"; return; }
  local got
  got="$(jq -r '[.branch, .commit] | join("|")' <<<"$out")"
  if [ "$got" != "$branch.teleport-1111|$sha" ]; then
    fail "$name (expected the fallback branch at $sha, got $got)"; return
  fi
  [ -d "$d/wt" ] || { fail "$name (worktree directory not created)"; return; }

  # A free branch name is used as-is, and the worktree lands on the commit.
  out="$(HOME="$d/home" "$rs" worktree --repo "$d/repo" --path "$d/wt2" \
          --branch feature --commit "$sha" --suffix 1111 2>&1)" \
    || { fail "$name (second worktree add failed: $out)"; return; }
  got="$(jq -r '.branch' <<<"$out")"
  [ "$got" = "feature" ] || { fail "$name (free branch name not used: $got)"; return; }
  [ "$(git -C "$d/wt2" rev-parse HEAD)" = "$sha" ] \
    || { fail "$name (worktree is not on the requested commit)"; return; }

  # Re-running against an existing worktree is a no-op, not an error.
  out="$(HOME="$d/home" "$rs" worktree --repo "$d/repo" --path "$d/wt2" \
          --branch feature --commit "$sha" --suffix 1111 2>&1)" \
    || { fail "$name (re-running worktree should be idempotent: $out)"; return; }
  jq -e '.created == false' >/dev/null <<<"$out" \
    || { fail "$name (idempotent re-run should report created=false)"; return; }

  # An unknown commit is refused rather than silently checked out elsewhere.
  HOME="$d/home" "$rs" worktree --repo "$d/repo" --path "$d/wt3" --branch x \
    --commit 0000000000000000000000000000000000000000 --suffix 1111 >/dev/null 2>&1
  [ "$?" -eq 5 ] || { fail "$name (an unknown commit should exit 5)"; return; }

  # register merges one project key without disturbing the rest of the file.
  echo '{"numStartups":7,"projects":{"/other":{"hasTrustDialogAccepted":true}}}' >"$d/home/.claude.json"
  mkdir -p "$d/home/.claude/ssh-teleport"
  cat >"$d/home/.claude/ssh-teleport/$sid.history.jsonl" <<EOF
{"display":"look","pastedContents":{},"timestamp":1,"project":"$d/wt2","sessionId":"$sid"}
EOF
  out="$(HOME="$d/home" "$rs" register --path "$d/wt2" --session-id "$sid" 2>&1)" \
    || { fail "$name (register failed: $out)"; return; }
  got="$(jq -r --arg p "$d/wt2" '[(.numStartups|tostring), (.projects[$p].hasTrustDialogAccepted|tostring),
                                  (.projects["/other"].hasTrustDialogAccepted|tostring)] | join("|")' \
         "$d/home/.claude.json")"
  [ "$got" = "7|true|true" ] || { fail "$name (claude.json merge wrong: $got)"; return; }
  [ "$(wc -l <"$d/home/.claude/history.jsonl")" -eq 1 ] \
    || { fail "$name (history line not appended)"; return; }

  # register twice must not duplicate the history line.
  HOME="$d/home" "$rs" register --path "$d/wt2" --session-id "$sid" >/dev/null 2>&1
  [ "$(wc -l <"$d/home/.claude/history.jsonl")" -eq 1 ] \
    || { fail "$name (register duplicated the history line)"; return; }

  # verify accepts a session landed at the encoded path for the worktree, and
  # rejects one whose recorded cwd points somewhere else.
  local real; real="$(cd "$d/wt2" && pwd -P)"
  local enc; enc="$(printf '%s' "$real" | sed 's/[^a-zA-Z0-9]/-/g')"
  mkdir -p "$d/home/.claude/projects/$enc"
  printf '%s\n' "{\"type\":\"user\",\"uuid\":\"u1\",\"cwd\":\"$real\",\"sessionId\":\"$sid\"}" \
    >"$d/home/.claude/projects/$enc/$sid.jsonl"
  out="$(HOME="$d/home" "$rs" verify --path "$d/wt2" --session-id "$sid" 2>&1)" \
    || { fail "$name (verify rejected a correctly landed session: $out)"; return; }
  jq -e '.worktree and .transcriptPresent and .resumable and .cwdMatches and .trusted' \
     >/dev/null <<<"$out" || { fail "$name (verify reported a bad state: $out)"; return; }

  printf '%s\n' "{\"type\":\"user\",\"uuid\":\"u1\",\"cwd\":\"/elsewhere\",\"sessionId\":\"$sid\"}" \
    >"$d/home/.claude/projects/$enc/$sid.jsonl"
  HOME="$d/home" "$rs" verify --path "$d/wt2" --session-id "$sid" >/dev/null 2>&1
  [ "$?" -eq 6 ] || { fail "$name (verify should exit 6 on a cwd mismatch)"; return; }

  pass "$name"
}

test_ssh_teleport_remote_setup_check_repo() {
  local name="skill ssh-teleport: remote-setup.sh check-repo verifies a --summary teleport"
  local d; d="$(mktemp -d)"; SANDBOXES+=("$d")
  local rs="$REPO/skills/ssh-teleport/scripts/remote-setup.sh"

  mkdir -p "$d/repo"
  git -C "$d/repo" init -q --initial-branch=main
  git -C "$d/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  local sha; sha="$(git -C "$d/repo" rev-parse HEAD)"
  git -C "$d/repo" worktree add "$d/wt" -b feature "$sha" >/dev/null

  # No --summary-file: only the worktree and its commit are checked.
  local out
  out="$("$rs" check-repo --path "$d/wt" --commit "$sha" 2>&1)" \
    || { fail "$name (check-repo failed on a clean worktree: $out)"; return; }
  jq -e '.worktree and .commitMatches and .summaryPresent' >/dev/null <<<"$out" \
    || { fail "$name (a clean worktree should report everything true: $out)"; return; }

  # Uncommitted files (the whole point of --summary mode) do not move HEAD, so
  # they must not trip the commit check.
  echo dirty >"$d/wt/dirty.txt"
  out="$("$rs" check-repo --path "$d/wt" --commit "$sha" 2>&1)" \
    || { fail "$name (an uncommitted file should not fail check-repo: $out)"; return; }

  # The handoff summary is checked when named, and its absence is exit 7.
  "$rs" check-repo --path "$d/wt" --commit "$sha" --summary-file "TELEPORT-2026.md" >/dev/null 2>&1
  [ "$?" -eq 7 ] || { fail "$name (a missing summary file should exit 7)"; return; }
  echo "# handoff" >"$d/wt/TELEPORT-2026.md"
  out="$("$rs" check-repo --path "$d/wt" --commit "$sha" --summary-file "TELEPORT-2026.md" 2>&1)" \
    || { fail "$name (check-repo failed once the summary file exists: $out)"; return; }
  jq -e '.summaryPresent' >/dev/null <<<"$out" \
    || { fail "$name (an existing summary file should report summaryPresent: $out)"; return; }

  # A commit mismatch is exit 7 too.
  git -C "$d/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m second
  "$rs" check-repo --path "$d/wt" --commit "$(git -C "$d/repo" rev-parse HEAD)" >/dev/null 2>&1
  [ "$?" -eq 7 ] || { fail "$name (a commit mismatch should exit 7)"; return; }

  # A path that is not a worktree at all is exit 7, not a crash.
  mkdir -p "$d/notawt"
  "$rs" check-repo --path "$d/notawt" --commit "$sha" >/dev/null 2>&1
  [ "$?" -eq 7 ] || { fail "$name (a non-worktree path should exit 7)"; return; }

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
test_ssh_teleport_encodes_paths
test_ssh_teleport_rewrites_transcript
test_ssh_teleport_probe_parses_target
test_ssh_teleport_remote_setup_worktree
test_ssh_teleport_remote_setup_check_repo

echo
if [ "$FAILURES" -eq 0 ]; then
  echo "All tests passed."
  exit 0
else
  echo "$FAILURES test(s) failed."
  exit 1
fi
