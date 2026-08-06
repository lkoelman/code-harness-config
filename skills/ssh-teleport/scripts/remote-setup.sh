#!/usr/bin/env bash
# The target-side half of ssh-teleport. Designed to be streamed in rather than
# installed, so it is self-contained and sources nothing:
#
#   ssh <host> bash -s -- worktree --repo ... < remote-setup.sh
#
# Subcommands:
#   worktree --repo <path> --path <path> --branch <name> --commit <sha> --suffix <s>
#       Add a git worktree at <path>, on <branch> if that name is free and on
#       <branch>.teleport-<suffix> otherwise, checked out at exactly <commit>.
#       Prints the worktree's real path, which is what the transcript and the
#       ~/.claude.json key must both use. Exit 5 if <commit> is unknown here.
#   register --path <path> [--session-id <uuid>]
#       Merge one project entry into ~/.claude.json so the first `claude` run in
#       the worktree does not stop on the trust dialog, and append this session's
#       prompt-history lines.
#   verify --path <path> --session-id <uuid>
#       Check the landed session without launching Claude. Exit 6 if it would not
#       resume.
set -uo pipefail
export LC_ALL=C

# Usage goes through a function rather than re-reading "$0": when this script is
# streamed over ssh there is no file on disk to read the header block back from.
usage() {
  cat <<'EOF'
usage: remote-setup.sh worktree --repo <path> --path <path> --branch <name> --commit <sha> --suffix <s>
       remote-setup.sh register --path <path> [--session-id <uuid>]
       remote-setup.sh verify   --path <path> --session-id <uuid>
EOF
}

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "error: git is required" >&2; exit 1; }

if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  CLAUDE_DIR="$CLAUDE_CONFIG_DIR"
  CONFIG="$CLAUDE_CONFIG_DIR/.claude.json"
else
  CLAUDE_DIR="$HOME/.claude"
  CONFIG="$HOME/.claude.json"
fi

# The same encoding rule as stage-session.sh, repeated rather than shared because
# this script has to stand alone on the far end of a pipe.
encode_project_dir() {
  printf '%s' "$1" | sed 's/[^a-zA-Z0-9]/-/g'
}

CMD="${1:-}"
[ "$#" -gt 0 ] && shift

case "$CMD" in
  worktree)
    REPO=""; WT_PATH=""; BRANCH=""; COMMIT=""; SUFFIX=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --repo) REPO="${2:-}"; shift 2 ;;
        --path) WT_PATH="${2:-}"; shift 2 ;;
        --branch) BRANCH="${2:-}"; shift 2 ;;
        --commit) COMMIT="${2:-}"; shift 2 ;;
        --suffix) SUFFIX="${2:-}"; shift 2 ;;
        *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
      esac
    done
    if [ -z "$REPO" ] || [ -z "$WT_PATH" ] || [ -z "$BRANCH" ] || [ -z "$COMMIT" ] || [ -z "$SUFFIX" ]; then
      echo "error: worktree needs --repo, --path, --branch, --commit and --suffix" >&2
      exit 1
    fi
    git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || {
      echo "error: '$REPO' is not a git repository" >&2; exit 1; }

    # Refuse rather than check out something close: a worktree on the wrong
    # commit would silently disagree with the transcript being restored.
    git -C "$REPO" cat-file -e "$COMMIT^{commit}" 2>/dev/null || {
      echo "error: commit $COMMIT is not present in $REPO — fetch it first" >&2; exit 5; }

    CREATED=true
    if [ -e "$WT_PATH" ]; then
      git -C "$WT_PATH" rev-parse --git-dir >/dev/null 2>&1 || {
        echo "error: '$WT_PATH' already exists and is not a git worktree" >&2; exit 1; }
      CREATED=false
    else
      NAME="$BRANCH"
      git -C "$REPO" show-ref --verify --quiet "refs/heads/$NAME" && NAME="$BRANCH.teleport-$SUFFIX"
      if git -C "$REPO" show-ref --verify --quiet "refs/heads/$NAME"; then
        # A previous run left this branch behind; reuse it only if it still
        # points where the session expects.
        if [ "$(git -C "$REPO" rev-parse "$NAME")" != "$COMMIT" ]; then
          echo "error: branch '$NAME' already exists here and is not at $COMMIT" >&2
          exit 1
        fi
        git -C "$REPO" worktree add "$WT_PATH" "$NAME" >/dev/null 2>&1 || {
          echo "error: could not add worktree at '$WT_PATH' on '$NAME'" >&2; exit 1; }
      else
        git -C "$REPO" worktree add -b "$NAME" "$WT_PATH" "$COMMIT" >/dev/null 2>&1 || {
          echo "error: could not add worktree at '$WT_PATH' on new branch '$NAME'" >&2; exit 1; }
      fi
    fi

    REAL_PATH="$(cd "$WT_PATH" && pwd -P)"
    jq -n --arg path "$REAL_PATH" --arg repo "$REPO" \
          --arg branch "$(git -C "$REAL_PATH" branch --show-current)" \
          --arg commit "$(git -C "$REAL_PATH" rev-parse HEAD)" \
          --argjson created "$CREATED" \
      '{path: $path, repo: $repo, branch: $branch, commit: $commit, created: $created}'
    ;;

  register)
    WT_PATH=""; SID=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --path) WT_PATH="${2:-}"; shift 2 ;;
        --session-id) SID="${2:-}"; shift 2 ;;
        *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
      esac
    done
    [ -n "$WT_PATH" ] || { echo "error: register needs --path" >&2; exit 1; }

    # Only ever add one key. This file also holds machineID, userID and the
    # account's oauth entry, so it is merged in place and never replaced.
    [ -f "$CONFIG" ] || echo '{}' >"$CONFIG"
    tmp="$CONFIG.ssh-teleport.tmp"
    jq --arg p "$WT_PATH" \
       '.projects = ((.projects // {}) | .[$p] = ((.[$p] // {}) + {hasTrustDialogAccepted: true}))' \
       "$CONFIG" >"$tmp" || { rm -f "$tmp"; echo "error: could not merge into $CONFIG" >&2; exit 1; }
    mv "$tmp" "$CONFIG"

    APPENDED=0
    FRAGMENT="$CLAUDE_DIR/ssh-teleport/$SID.history.jsonl"
    if [ -n "$SID" ] && [ -s "$FRAGMENT" ]; then
      mkdir -p "$CLAUDE_DIR"
      touch "$CLAUDE_DIR/history.jsonl"
      # Skip if this session's prompts are already there, so re-teleporting the
      # same session does not duplicate its up-arrow history.
      if ! grep -q "\"$SID\"" "$CLAUDE_DIR/history.jsonl" 2>/dev/null; then
        cat "$FRAGMENT" >>"$CLAUDE_DIR/history.jsonl"
        APPENDED="$(grep -c '^' "$FRAGMENT")"
      fi
    fi

    jq -n --arg path "$WT_PATH" --argjson appended "$APPENDED" \
      '{path: $path, registered: true, historyLinesAppended: $appended}'
    ;;

  verify)
    WT_PATH=""; SID=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --path) WT_PATH="${2:-}"; shift 2 ;;
        --session-id) SID="${2:-}"; shift 2 ;;
        *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
      esac
    done
    if [ -z "$WT_PATH" ] || [ -z "$SID" ]; then
      echo "error: verify needs --path and --session-id" >&2; exit 1
    fi

    REAL_PATH="$(cd "$WT_PATH" 2>/dev/null && pwd -P)" || REAL_PATH=""
    WORKTREE_OK=false
    [ -n "$REAL_PATH" ] && git -C "$REAL_PATH" rev-parse --git-dir >/dev/null 2>&1 && WORKTREE_OK=true

    ENC="$(encode_project_dir "${REAL_PATH:-$WT_PATH}")"
    TRANSCRIPT="$CLAUDE_DIR/projects/$ENC/$SID.jsonl"

    TRANSCRIPT_OK=false; RESUMABLE=false; CWD_OK=false; TRANSCRIPT_CWD=""
    if [ -f "$TRANSCRIPT" ]; then
      TRANSCRIPT_OK=true
      grep -q '"type":"user"\|"type":"assistant"' "$TRANSCRIPT" && RESUMABLE=true
      TRANSCRIPT_CWD="$(jq -rs 'map(select(.cwd)) | .[0].cwd // ""' "$TRANSCRIPT" 2>/dev/null)"
      [ "$TRANSCRIPT_CWD" = "$REAL_PATH" ] && CWD_OK=true
    fi

    TRUSTED=false
    if [ -f "$CONFIG" ]; then
      jq -e --arg p "$REAL_PATH" '.projects[$p].hasTrustDialogAccepted == true' \
         "$CONFIG" >/dev/null 2>&1 && TRUSTED=true
    fi

    jq -n --arg path "$REAL_PATH" --arg transcript "$TRANSCRIPT" --arg enc "$ENC" \
          --arg transcriptCwd "$TRANSCRIPT_CWD" \
          --argjson worktree "$WORKTREE_OK" --argjson transcriptPresent "$TRANSCRIPT_OK" \
          --argjson resumable "$RESUMABLE" --argjson cwdMatches "$CWD_OK" \
          --argjson trusted "$TRUSTED" \
      '{path: $path, encodedDir: $enc, transcript: $transcript,
        transcriptCwd: $transcriptCwd, worktree: $worktree,
        transcriptPresent: $transcriptPresent, resumable: $resumable,
        cwdMatches: $cwdMatches, trusted: $trusted}'

    if [ "$WORKTREE_OK" != true ] || [ "$TRANSCRIPT_OK" != true ] \
       || [ "$RESUMABLE" != true ] || [ "$CWD_OK" != true ]; then
      echo "error: the session would not resume at $WT_PATH" >&2
      exit 6
    fi
    ;;

  ''|-h|--help)
    usage
    ;;

  *)
    echo "error: unknown command '$CMD'" >&2
    usage >&2
    exit 1
    ;;
esac
