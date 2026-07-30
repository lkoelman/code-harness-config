#!/usr/bin/env bash
# Bookkeeping for an autofix-pr-local run: attempt budget, per-check error
# signatures (the no-progress guard), handled review threads, and the commits
# this run created. State lives in the git directory, so it is never committed
# and stays correct inside worktrees.
#
# Usage:
#   pr-state.sh init --pr <n> --max-attempts <N> --mode <mode> [--start-commit <sha>]
#   pr-state.sh show
#   pr-state.sh attempt                       # exit 1 when the budget is spent
#   pr-state.sh signature <check> <signature> # exit 3 when unchanged (no progress)
#   pr-state.sh thread-seen <thread-id>       # exit 0 if already handled
#   pr-state.sh thread-done <thread-id>
#   pr-state.sh commit <sha> <description>
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

GIT_DIR="$(git rev-parse --git-dir 2>/dev/null)" || {
  echo "error: not inside a git repository" >&2
  exit 1
}
STATE_DIR="$GIT_DIR/autofix-pr-local"
STATE="$STATE_DIR/state.json"

require_state() {
  if [ ! -f "$STATE" ]; then
    echo "error: no run state — call 'pr-state.sh init' first" >&2
    exit 1
  fi
}

# write <jq-filter> [args...] — rewrite the state file through jq atomically.
write() {
  local filter="$1"; shift
  local tmp="$STATE.tmp"
  jq "$@" "$filter" "$STATE" >"$tmp" || { rm -f "$tmp"; exit 1; }
  mv "$tmp" "$STATE"
}

CMD="${1:-}"
[ "$#" -gt 0 ] && shift

case "$CMD" in
  init)
    PR=""; MAX=""; MODE=""; START_COMMIT=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --pr) PR="${2:-}"; shift 2 ;;
        --max-attempts) MAX="${2:-}"; shift 2 ;;
        --mode) MODE="${2:-}"; shift 2 ;;
        --start-commit) START_COMMIT="${2:-}"; shift 2 ;;
        *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
      esac
    done
    if [ -z "$PR" ] || [ -z "$MAX" ] || [ -z "$MODE" ]; then
      echo "error: init needs --pr, --max-attempts and --mode" >&2
      exit 1
    fi
    case "$MAX" in
      ''|*[!0-9]*) echo "error: --max-attempts must be a positive integer" >&2; exit 1 ;;
      0) echo "error: --max-attempts must be at least 1" >&2; exit 1 ;;
    esac
    [ -n "$START_COMMIT" ] || START_COMMIT="$(git rev-parse HEAD 2>/dev/null)"
    mkdir -p "$STATE_DIR"

    # Resuming the same PR keeps the tally; a different PR starts fresh.
    if [ -f "$STATE" ] && [ "$(jq -r '.pr' "$STATE")" = "$PR" ]; then
      write '.max_attempts = $max | .mode = $mode' \
        --argjson max "$MAX" --arg mode "$MODE"
      echo "resumed run for PR #$PR ($(jq -r '.attempts_used' "$STATE")/$MAX attempts used)"
    else
      jq -n --argjson pr "$PR" --argjson max "$MAX" --arg mode "$MODE" \
            --arg start "$START_COMMIT" \
        '{pr: $pr, max_attempts: $max, mode: $mode, start_commit: $start,
          attempts_used: 0, check_signatures: {}, handled_threads: [],
          stalled_checks: [], commits: []}' >"$STATE"
      echo "initialised run for PR #$PR"
    fi
    ;;

  show)
    require_state
    cat "$STATE"
    ;;

  attempt)
    require_state
    used="$(jq -r '.attempts_used' "$STATE")"
    max="$(jq -r '.max_attempts' "$STATE")"
    if [ "$used" -ge "$max" ]; then
      echo "attempt budget exhausted ($used/$max)" >&2
      exit 1
    fi
    write '.attempts_used += 1'
    used=$((used + 1))
    echo "attempt $used/$max"
    ;;

  signature)
    require_state
    check="${1:-}"; sig="${2:-}"
    if [ -z "$check" ] || [ -z "$sig" ]; then
      echo "error: signature needs <check> <signature>" >&2
      exit 1
    fi
    prev="$(jq -r --arg c "$check" '.check_signatures[$c] // ""' "$STATE")"
    if [ "$prev" = "$sig" ]; then
      write '.stalled_checks = (.stalled_checks + [$c] | unique)' --arg c "$check"
      echo "no progress on '$check': same failure signature as last attempt" >&2
      exit 3
    fi
    write '.check_signatures[$c] = $s' --arg c "$check" --arg s "$sig"
    echo "recorded signature for '$check'"
    ;;

  thread-seen)
    require_state
    id="${1:-}"
    [ -n "$id" ] || { echo "error: thread-seen needs <thread-id>" >&2; exit 1; }
    if jq -e --arg id "$id" '.handled_threads | index($id)' "$STATE" >/dev/null; then
      echo "already handled"
      exit 0
    fi
    echo "not handled"
    exit 1
    ;;

  thread-done)
    require_state
    id="${1:-}"
    [ -n "$id" ] || { echo "error: thread-done needs <thread-id>" >&2; exit 1; }
    write '.handled_threads = (.handled_threads + [$id] | unique)' --arg id "$id"
    echo "marked $id handled"
    ;;

  commit)
    require_state
    sha="${1:-}"; desc="${2:-}"
    if [ -z "$sha" ] || [ -z "$desc" ]; then
      echo "error: commit needs <sha> <description>" >&2
      exit 1
    fi
    write '.commits += [{sha: $sha, description: $desc}]' --arg sha "$sha" --arg desc "$desc"
    echo "recorded commit $sha"
    ;;

  ''|-h|--help)
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
    ;;

  *)
    echo "error: unknown command '$CMD'" >&2
    exit 1
    ;;
esac
