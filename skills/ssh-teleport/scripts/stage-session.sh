#!/usr/bin/env bash
# Stages one Claude Code session for a different machine and directory: builds a
# mirror of the target's ~/.claude under --out, with every source path rewritten
# to where it will live on the target. Nothing under the real ~/.claude is
# touched, so a failed teleport leaves this machine's session intact.
#
# Prints a JSON manifest. Exit 4 means the target path cannot be encoded the way
# Claude Code would encode it, so staging would put the transcript somewhere
# --resume cannot deterministically find.
#
# Usage:
#   stage-session.sh --session-id <uuid> --target-cwd <abs path>
#                    --target-home <abs path> --target-branch <branch>
#                    --out <dir>
set -uo pipefail

# Byte-wise, locale-independent: the ASCII guard and the encoder below must not
# change behaviour with the caller's locale.
export LC_ALL=C

command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

SID=""; TARGET_CWD=""; TARGET_HOME=""; TARGET_BRANCH=""; OUT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session-id) SID="${2:-}"; shift 2 ;;
    --target-cwd) TARGET_CWD="${2:-}"; shift 2 ;;
    --target-home) TARGET_HOME="${2:-}"; shift 2 ;;
    --target-branch) TARGET_BRANCH="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    -h|--help)
      awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
      exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

if [ -z "$SID" ] || [ -z "$TARGET_CWD" ] || [ -z "$TARGET_HOME" ] || [ -z "$TARGET_BRANCH" ] || [ -z "$OUT" ]; then
  echo "error: --session-id, --target-cwd, --target-home, --target-branch and --out are all required" >&2
  exit 1
fi
case "$TARGET_CWD" in /*) ;; *) echo "error: --target-cwd must be absolute" >&2; exit 1 ;; esac
case "$TARGET_HOME" in /*) ;; *) echo "error: --target-home must be absolute" >&2; exit 1 ;; esac

# encode_project_dir <abs path> — reproduce Claude Code's ~/.claude/projects
# directory name: every character that is not [a-zA-Z0-9] becomes '-'. Refuses
# the two cases bash cannot reproduce faithfully rather than guessing at them:
# non-ASCII (Claude substitutes per UTF-16 code unit, sed per byte) and a name
# over 200 characters (truncated and suffixed with an internal hash).
encode_project_dir() {
  local path="$1"
  case "$path" in
    *[!\ -~]*)
      echo "error: target path contains non-ASCII characters, whose encoding cannot be reproduced here — use an ASCII path" >&2
      exit 4 ;;
  esac
  local enc
  enc="$(printf '%s' "$path" | sed 's/[^a-zA-Z0-9]/-/g')"
  if [ "${#enc}" -gt 200 ]; then
    echo "error: target path encodes to ${#enc} characters (limit 200), where Claude Code appends a hash we cannot reproduce — use a shorter path" >&2
    exit 4
  fi
  printf '%s' "$enc"
}

# Locate the transcript by session id rather than by re-encoding this machine's
# cwd: the encoding is lossy, so two directories can share a name.
SRC_TRANSCRIPT=""
for f in "$CLAUDE_DIR"/projects/*/"$SID.jsonl"; do
  [ -f "$f" ] || continue
  if [ -n "$SRC_TRANSCRIPT" ]; then
    echo "error: session $SID appears in more than one project directory under $CLAUDE_DIR/projects" >&2
    exit 1
  fi
  SRC_TRANSCRIPT="$f"
done
if [ -z "$SRC_TRANSCRIPT" ]; then
  echo "error: no transcript for session $SID under $CLAUDE_DIR/projects" >&2
  exit 1
fi
SRC_SIDECAR="${SRC_TRANSCRIPT%.jsonl}"

# The session's own record of where it ran, which is what has to be rewritten.
SRC_CWD="$(jq -rs 'map(select(.cwd)) | .[0].cwd // ""' "$SRC_TRANSCRIPT")"
if [ -z "$SRC_CWD" ]; then
  echo "error: transcript $SRC_TRANSCRIPT has no cwd to rewrite" >&2
  exit 1
fi
SLUG="$(jq -rs 'map(select(.slug)) | .[0].slug // ""' "$SRC_TRANSCRIPT")"

ENC="$(encode_project_dir "$TARGET_CWD")" || exit $?

STAGE_CLAUDE="$OUT/.claude"
mkdir -p "$STAGE_CLAUDE/projects/$ENC" "$STAGE_CLAUDE/ssh-teleport" || exit 1

# The two substitutions, longest-scope first: the session's directory, then
# whatever is left pointing at this machine's home (plan files, scratchpads).
REWRITE='
  def rep: if type == "string"
           then ((. / $srcCwd | join($dstCwd)) / $srcHome | join($dstHome))
           else . end;
  walk(if type == "object" then with_entries(.key |= rep) else rep end)
  | if type == "object" and has("gitBranch") then .gitBranch = $branch else . end
'

# rewrite_json <src> <dst> — for .jsonl streams and single-object .json alike.
rewrite_json() {
  jq -c --arg srcCwd "$SRC_CWD" --arg dstCwd "$TARGET_CWD" \
        --arg srcHome "$HOME" --arg dstHome "$TARGET_HOME" \
        --arg branch "$TARGET_BRANCH" "$REWRITE" "$1" >"$2"
}

# rewrite_text <src> <dst> — same substitutions for the plain-text files
# (saved tool results, plan files). Quoting the patterns keeps them literal.
rewrite_text() {
  local line
  : >"$2"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//"$SRC_CWD"/"$TARGET_CWD"}"
    printf '%s\n' "${line//"$HOME"/"$TARGET_HOME"}" >>"$2"
  done <"$1"
}

STAGED_TRANSCRIPT="$STAGE_CLAUDE/projects/$ENC/$SID.jsonl"
rewrite_json "$SRC_TRANSCRIPT" "$STAGED_TRANSCRIPT" || {
  echo "error: could not rewrite $SRC_TRANSCRIPT (malformed transcript?)" >&2
  exit 1
}

# Claude Code only treats a transcript as resumable if it holds a user or
# assistant line, so a rewrite that lost them would resume to nothing.
if ! grep -q '"type":"user"\|"type":"assistant"' "$STAGED_TRANSCRIPT"; then
  echo "error: staged transcript has no user or assistant entry, so it would not resume" >&2
  exit 1
fi

# Sidecars: subagent transcripts and their metadata are JSON, saved tool results
# are text. The transcript references all of them by relative name.
SUBAGENTS=0; TOOL_RESULTS=0
if [ -d "$SRC_SIDECAR" ]; then
  while IFS= read -r f; do
    rel="${f#"$SRC_SIDECAR/"}"
    mkdir -p "$STAGE_CLAUDE/projects/$ENC/$SID/$(dirname "$rel")"
    case "$f" in
      *.jsonl|*.json)
        rewrite_json "$f" "$STAGE_CLAUDE/projects/$ENC/$SID/$rel" || exit 1
        case "$f" in *.jsonl) SUBAGENTS=$((SUBAGENTS + 1)) ;; esac ;;
      *)
        rewrite_text "$f" "$STAGE_CLAUDE/projects/$ENC/$SID/$rel"
        TOOL_RESULTS=$((TOOL_RESULTS + 1)) ;;
    esac
  done < <(find "$SRC_SIDECAR" -type f)
fi

# File history is copied byte-for-byte: these are snapshots of file *contents*,
# and rewriting inside them would corrupt what /rewind restores. The names are
# hashes of tracking paths, which are relative for in-repo files and so stay
# valid at the new location.
FILE_HISTORY=0
if [ -d "$CLAUDE_DIR/file-history/$SID" ]; then
  mkdir -p "$STAGE_CLAUDE/file-history"
  cp -r "$CLAUDE_DIR/file-history/$SID" "$STAGE_CLAUDE/file-history/" || exit 1
  FILE_HISTORY="$(find "$STAGE_CLAUDE/file-history/$SID" -type f | wc -l)"
fi

# Task numbering, but never the lock file: a stale lock on the target would
# look like another process holding the task list.
if [ -f "$CLAUDE_DIR/tasks/$SID/.highwatermark" ]; then
  mkdir -p "$STAGE_CLAUDE/tasks/$SID"
  cp "$CLAUDE_DIR/tasks/$SID/.highwatermark" "$STAGE_CLAUDE/tasks/$SID/" || exit 1
fi

if [ -d "$CLAUDE_DIR/session-env/$SID" ] && [ -n "$(ls -A "$CLAUDE_DIR/session-env/$SID" 2>/dev/null)" ]; then
  mkdir -p "$STAGE_CLAUDE/session-env"
  cp -r "$CLAUDE_DIR/session-env/$SID" "$STAGE_CLAUDE/session-env/" || exit 1
fi

# Plan files are referenced from the transcript by absolute path, so collect them
# from the transcript itself as well as from the session's slug.
PLAN_FILES=()
{
  [ -n "$SLUG" ] && printf '%s\n' "$CLAUDE_DIR/plans/$SLUG.md"
  jq -rs '[.[] | .attachment?.planFilePath?, (.message?.content? | if type == "array" then .[].input?.planFilePath? else empty end)]
          | map(select(. != null)) | unique | .[]' "$SRC_TRANSCRIPT" 2>/dev/null
} | sort -u | while IFS= read -r p; do
  [ -n "$p" ] && [ -f "$p" ] && printf '%s\n' "$p"
done >"$OUT/.plan-files" || true
while IFS= read -r p; do
  [ -n "$p" ] || continue
  mkdir -p "$STAGE_CLAUDE/plans"
  rewrite_text "$p" "$STAGE_CLAUDE/plans/$(basename "$p")"
  PLAN_FILES+=("$STAGE_CLAUDE/plans/$(basename "$p")")
done <"$OUT/.plan-files"
rm -f "$OUT/.plan-files"

# The prompt-recall lines for this session only, with the project path rewritten.
# register on the target appends these; overwriting its history.jsonl would
# throw away every prompt it has of its own.
HISTORY_FRAGMENT="$STAGE_CLAUDE/ssh-teleport/$SID.history.jsonl"
: >"$HISTORY_FRAGMENT"
if [ -f "$CLAUDE_DIR/history.jsonl" ]; then
  jq -c --arg sid "$SID" --arg p "$TARGET_CWD" \
     'select(.sessionId == $sid) | .project = $p' \
     "$CLAUDE_DIR/history.jsonl" >"$HISTORY_FRAGMENT" 2>/dev/null || : >"$HISTORY_FRAGMENT"
fi

jq -n --arg sid "$SID" --arg srcCwd "$SRC_CWD" --arg dstCwd "$TARGET_CWD" \
      --arg enc "$ENC" --arg branch "$TARGET_BRANCH" --arg slug "$SLUG" \
      --arg stage "$OUT" \
      --argjson entries "$(wc -l <"$STAGED_TRANSCRIPT")" \
      --argjson bytes "$(wc -c <"$STAGED_TRANSCRIPT")" \
      --argjson subagents "$SUBAGENTS" --argjson toolResults "$TOOL_RESULTS" \
      --argjson fileHistory "$FILE_HISTORY" \
      --argjson historyLines "$(wc -l <"$HISTORY_FRAGMENT")" \
      --argjson planFiles "$(printf '%s\n' "${PLAN_FILES[@]:-}" | jq -Rc 'select(. != "")' | jq -sc .)" \
  '{sessionId: $sid, sourceCwd: $srcCwd, targetCwd: $dstCwd, encodedDir: $enc,
    targetBranch: $branch, slug: $slug, stageDir: $stage, entries: $entries,
    bytes: $bytes, subagentTranscripts: $subagents, toolResults: $toolResults,
    fileHistoryEntries: $fileHistory, planFiles: $planFiles,
    historyLines: $historyLines}'
