#!/usr/bin/env bash
# Collects everything ssh-teleport needs to know about a target machine in one
# round trip, and prints it as a single JSON document. Read-only: it inspects the
# target but changes nothing there.
#
# Must be run from inside the session's git repository — origin, HEAD and the
# branch are read from it.
#
# The remote round trip uses `ssh -A` so that `agentForwardingOk` reflects what a
# later `git clone`/`git fetch` on the target would actually get.
#
# Exit 2 = target unreachable. Exit 3 = target is missing one of --require's
# dependencies (default: claude, jq, rsync and git — pass `--require rsync,jq,git`
# for a --summary teleport, which is the only one of the four that never needs
# `claude` on the target; jq and git are still required, because remote-setup.sh
# uses both in every mode).
#
# Usage:
#   probe-target.sh --host <host> [--user <user>] [--repo-path <path>]
#                    [--require <comma-list, default jq,rsync,git,claude>]
set -uo pipefail

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

HOST=""; USER_OVERRIDE=""; REPO_PATH_HINT=""; REQUIRE="jq,rsync,git,claude"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2 ;;
    --user) USER_OVERRIDE="${2:-}"; shift 2 ;;
    --repo-path) REPO_PATH_HINT="${2:-}"; shift 2 ;;
    --require) REQUIRE="${2:-}"; shift 2 ;;
    -h|--help)
      awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
      exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done
[ -n "$HOST" ] || { echo "error: --host is required" >&2; exit 1; }

ORIGIN_URL="$(git remote get-url origin 2>/dev/null)" || {
  echo "error: not inside a git repository with an 'origin' remote" >&2
  exit 1
}
COMMIT="$(git rev-parse HEAD 2>/dev/null)"
BRANCH="$(git branch --show-current 2>/dev/null)"
REPO_NAME="$(basename "$(git rev-parse --show-toplevel)")"
SID="${CLAUDE_CODE_SESSION_ID:-}"

# `ssh -G` always prints a user, falling back to the local one for a host it has
# never heard of — so it is only evidence when the host has a real Host block.
CFG_USER=""; CFG_HOSTNAME=""; CFG_PORT="22"
while read -r key value; do
  case "$key" in
    user) CFG_USER="$value" ;;
    hostname) CFG_HOSTNAME="$value" ;;
    port) CFG_PORT="$value" ;;
  esac
done < <(ssh -G "$HOST" 2>/dev/null)

USER_FROM_CONFIG=false
if [ -f "$HOME/.ssh/config" ] && grep -qiE "^[[:space:]]*Host([[:space:]]+[^[:space:]]+)*[[:space:]]+$HOST([[:space:]]|$)" "$HOME/.ssh/config"; then
  USER_FROM_CONFIG=true
fi

TARGET_USER="${USER_OVERRIDE:-$CFG_USER}"
[ -n "$TARGET_USER" ] && DEST="$TARGET_USER@$HOST" || DEST="$HOST"

# One remote script, one round trip. It emits TAB-separated key/value lines and
# never writes anything on the target.
REMOTE_SCRIPT='
set -u
origin_url="$1"; commit="$2"; branch="$3"; repo_name="$4"; sid="$5"; hint="$6"

printf "remoteHome\t%s\n" "$HOME"
printf "claudeVersion\t%s\n" "$(command -v claude >/dev/null 2>&1 && claude --version 2>/dev/null)"
printf "hasJq\t%s\n" "$(command -v jq >/dev/null 2>&1 && echo yes || echo no)"
printf "hasRsync\t%s\n" "$(command -v rsync >/dev/null 2>&1 && echo yes || echo no)"
printf "hasGit\t%s\n" "$(command -v git >/dev/null 2>&1 && echo yes || echo no)"

# Agent forwarding is what lets the clone/fetch below use the caller keys.
if [ -n "${SSH_AUTH_SOCK:-}" ] && ssh-add -l >/dev/null 2>&1; then
  printf "agentForwardingOk\tyes\n"
else
  printf "agentForwardingOk\tno\n"
fi

repo=""
for cand in "$hint" "$HOME/$repo_name" "$HOME/code/$repo_name" "$HOME/src/$repo_name" \
            "$HOME/projects/$repo_name" "$HOME/repos/$repo_name" "$HOME/work/$repo_name"; do
  [ -n "$cand" ] || continue
  [ -d "$cand/.git" ] || [ -f "$cand/.git" ] || continue
  repo="$cand"
  [ "$(git -C "$cand" remote get-url origin 2>/dev/null)" = "$origin_url" ] && break
  repo=""
done
printf "repoPath\t%s\n" "$repo"

if [ -n "$repo" ]; then
  printf "originMatches\tyes\n"
  git -C "$repo" cat-file -e "$commit^{commit}" 2>/dev/null \
    && printf "headPresent\tyes\n" || printf "headPresent\tno\n"
  # Ref existence, not checked-out-ness: this is the exact condition
  # remote-setup.sh uses to decide whether to fall back to a suffixed branch
  # name, so the two must agree or the predicted name would be wrong.
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    printf "branchExists\tyes\n"
  else
    printf "branchExists\tno\n"
  fi
else
  printf "originMatches\tno\n"
  printf "headPresent\tno\n"
  printf "branchExists\tno\n"
fi

# A session already open on the target must not be written under.
live=no
for f in "$HOME"/.claude/sessions/*.json; do
  [ -f "$f" ] || continue
  grep -q "\"$sid\"" "$f" 2>/dev/null && live=yes
done
printf "sessionLive\t%s\n" "$live"
'

PROBE="$(printf '%s' "$REMOTE_SCRIPT" | ssh -A -o BatchMode=yes "$DEST" bash -s -- \
           "$ORIGIN_URL" "$COMMIT" "$BRANCH" "$REPO_NAME" "$SID" "$REPO_PATH_HINT" 2>&1)"
if [ "$?" -ne 0 ]; then
  echo "error: cannot reach $DEST — $(printf '%s' "$PROBE" | tail -1)" >&2
  exit 2
fi

REMOTE_HOME=""; CLAUDE_VERSION=""; HAS_JQ=no; HAS_RSYNC=no; HAS_GIT=no; AGENT_OK=no
REPO_PATH=""; ORIGIN_MATCHES=no; HEAD_PRESENT=no; BRANCH_EXISTS=no; SESSION_LIVE=no
while IFS=$'\t' read -r key value; do
  case "$key" in
    remoteHome) REMOTE_HOME="$value" ;;
    claudeVersion) CLAUDE_VERSION="${value%% *}" ;;
    hasJq) HAS_JQ="$value" ;;
    hasRsync) HAS_RSYNC="$value" ;;
    hasGit) HAS_GIT="$value" ;;
    agentForwardingOk) AGENT_OK="$value" ;;
    repoPath) REPO_PATH="$value" ;;
    originMatches) ORIGIN_MATCHES="$value" ;;
    headPresent) HEAD_PRESENT="$value" ;;
    branchExists) BRANCH_EXISTS="$value" ;;
    sessionLive) SESSION_LIVE="$value" ;;
  esac
done <<<"$PROBE"

if [ -z "$REMOTE_HOME" ]; then
  echo "error: $DEST answered but reported no home directory — $(printf '%s' "$PROBE" | tail -1)" >&2
  exit 2
fi

# Where the worktree goes by default: beside the target's clone, one directory
# per branch, using the branch's last segment so the leaf stays flat.
if [ -n "$REPO_PATH" ]; then
  WORKTREE_BASE="$(dirname "$REPO_PATH")/worktrees-$(basename "$REPO_PATH")"
else
  WORKTREE_BASE="$REMOTE_HOME/code/worktrees-$REPO_NAME"
fi
SUGGESTED_WORKTREE="$WORKTREE_BASE/${BRANCH##*/}"

LOCAL_AGENT_KEYS=0
if command -v ssh-add >/dev/null 2>&1; then
  LOCAL_AGENT_KEYS="$(ssh-add -l 2>/dev/null | grep -c '^' )"
  ssh-add -l >/dev/null 2>&1 || LOCAL_AGENT_KEYS=0
fi

# yesno <value> — the remote speaks yes/no, the JSON speaks true/false.
yesno() { [ "$1" = "yes" ] && echo true || echo false; }

jq -n --arg host "$HOST" --arg user "$TARGET_USER" --arg hostname "${CFG_HOSTNAME:-$HOST}" \
      --arg port "$CFG_PORT" --arg dest "$DEST" --arg remoteHome "$REMOTE_HOME" \
      --arg claudeVersion "$CLAUDE_VERSION" --arg repoPath "$REPO_PATH" \
      --arg originUrl "$ORIGIN_URL" --arg branch "$BRANCH" --arg commit "$COMMIT" \
      --arg suggested "$SUGGESTED_WORKTREE" \
      --argjson userFromConfig "$USER_FROM_CONFIG" \
      --argjson hasJq "$(yesno "$HAS_JQ")" --argjson hasRsync "$(yesno "$HAS_RSYNC")" \
      --argjson hasGit "$(yesno "$HAS_GIT")" \
      --argjson agentForwardingOk "$(yesno "$AGENT_OK")" \
      --argjson originMatches "$(yesno "$ORIGIN_MATCHES")" \
      --argjson headPresent "$(yesno "$HEAD_PRESENT")" \
      --argjson branchExists "$(yesno "$BRANCH_EXISTS")" \
      --argjson sessionLive "$(yesno "$SESSION_LIVE")" \
      --argjson localAgentKeys "$LOCAL_AGENT_KEYS" \
  '{host: $host, user: $user, hostname: $hostname, port: $port, dest: $dest,
    userFromConfig: $userFromConfig, remoteHome: $remoteHome,
    claudeVersion: $claudeVersion, hasJq: $hasJq, hasRsync: $hasRsync,
    hasGit: $hasGit,
    agentForwardingOk: $agentForwardingOk, localAgentKeys: $localAgentKeys,
    repoPath: $repoPath, originUrl: $originUrl, originMatches: $originMatches,
    headPresent: $headPresent, branch: $branch, commit: $commit,
    branchExists: $branchExists, sessionLive: $sessionLive,
    suggestedWorktreePath: $suggested}'

missing=""
case ",$REQUIRE," in *,jq,*) [ "$HAS_JQ" = "yes" ] || missing="$missing jq" ;; esac
case ",$REQUIRE," in *,rsync,*) [ "$HAS_RSYNC" = "yes" ] || missing="$missing rsync" ;; esac
case ",$REQUIRE," in *,git,*) [ "$HAS_GIT" = "yes" ] || missing="$missing git" ;; esac
case ",$REQUIRE," in *,claude,*) [ -n "$CLAUDE_VERSION" ] || missing="$missing claude" ;; esac
if [ -n "$missing" ]; then
  echo "error: $DEST is missing:$missing" >&2
  exit 3
fi
