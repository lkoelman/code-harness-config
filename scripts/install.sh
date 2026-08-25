#!/usr/bin/env bash
# Builds and symlinks skills/agents (and, for pi-agent, settings.json) into
# each harness's config directory, one symlink per item so unrelated content
# already in those directories is left untouched.
#
# Usage: scripts/install.sh (--all|<harness>...) [--dry-run] [--force]
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HARNESSES_DIR="$REPO/harnesses"
BUILD_DIR="$REPO/build"

DRY_RUN=0
FORCE=0
ALL=0
declare -a TARGETS=()

for arg in "$@"; do
  case "$arg" in
    --all) ALL=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    --*) echo "error: unknown flag '$arg'" >&2; exit 1 ;;
    *) TARGETS+=("$arg") ;;
  esac
done

mapfile -t KNOWN_HARNESSES < <(
  for f in "$HARNESSES_DIR"/*.conf; do
    [ -e "$f" ] || continue
    basename "$f" .conf
  done
)

if [ "$ALL" -eq 1 ]; then
  TARGETS=("${KNOWN_HARNESSES[@]}")
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "usage: install.sh (--all|<harness>...) [--dry-run] [--force]" >&2
  echo "known harnesses: ${KNOWN_HARNESSES[*]}" >&2
  exit 1
fi

for h in "${TARGETS[@]}"; do
  found=0
  for k in "${KNOWN_HARNESSES[@]}"; do [ "$k" = "$h" ] && found=1; done
  if [ "$found" -eq 0 ]; then
    echo "error: unknown harness '$h' (known: ${KNOWN_HARNESSES[*]})" >&2
    exit 1
  fi
done

if ! "$REPO/scripts/build.sh" "${TARGETS[@]}"; then
  exit 1
fi

FAIL=0

backup_path() {
  local dest="$1" candidate
  if [[ "$dest" == *.json ]]; then
    candidate="${dest%.json}.old.json"
  else
    candidate="$dest.bak"
  fi
  local i=1
  while [ -e "$candidate" ]; do
    candidate="$candidate.$i"
    i=$((i + 1))
  done
  echo "$candidate"
}

# link_item <source-in-build-or-repo> <dest-path> <label>
link_item() {
  local src="$1" dest="$2" label="$3"

  if [ -L "$dest" ]; then
    if [ "$(readlink "$dest")" = "$src" ]; then
      return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "would relink $label -> $dest"
      return 0
    fi
    ln -sfn "$src" "$dest"
    echo "relinked $label -> $dest"
    return 0
  fi

  if [ -e "$dest" ]; then
    if [ "$FORCE" -ne 1 ]; then
      echo "error: $dest exists and is not a symlink (refusing to clobber $label without --force)" >&2
      FAIL=1
      return 1
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "would back up existing $dest and replace with $label"
      return 0
    fi
    local backup; backup="$(backup_path "$dest")"
    mv "$dest" "$backup"
    echo "backed up existing $dest -> $backup"
    ln -s "$src" "$dest"
    echo "installed $label -> $dest"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would install $label -> $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  ln -s "$src" "$dest"
  echo "installed $label -> $dest"
}

# Removes symlinks in $1 whose target points into $REPO/build/ but no longer
# resolves to anything (leftover from a renamed/removed skill or agent).
prune_stale() {
  local dir="$1" link raw
  [ -d "$dir" ] || return 0
  for link in "$dir"/*; do
    [ -L "$link" ] || continue
    [ -e "$link" ] && continue
    raw="$(readlink "$link")"
    case "$raw" in
      "$REPO"/build/*)
        if [ "$DRY_RUN" -eq 1 ]; then
          echo "would prune stale link $link"
        else
          rm -f "$link"
          echo "pruned stale link $link"
        fi
        ;;
    esac
  done
}

for h in "${TARGETS[@]}"; do
  SKILLS_DIR=""
  AGENTS_DIR=""
  SETTINGS_DEST=""
  CLAUDE_MD_DEST=""
  # shellcheck disable=SC1090
  source "$HARNESSES_DIR/$h.conf"

  if [ -n "$SKILLS_DIR" ]; then
    [ "$DRY_RUN" -eq 1 ] || mkdir -p "$SKILLS_DIR"
    if [ -d "$BUILD_DIR/$h/skills" ]; then
      for item in "$BUILD_DIR/$h/skills"/*; do
        [ -e "$item" ] || continue
        name="$(basename "$item")"
        link_item "$item" "$SKILLS_DIR/$name" "skill $h/$name"
      done
    fi
    prune_stale "$SKILLS_DIR"
  fi

  if [ -n "$AGENTS_DIR" ]; then
    [ "$DRY_RUN" -eq 1 ] || mkdir -p "$AGENTS_DIR"
    if [ -d "$BUILD_DIR/$h/agents" ]; then
      for item in "$BUILD_DIR/$h/agents"/*; do
        [ -e "$item" ] || continue
        name="$(basename "$item")"
        link_item "$item" "$AGENTS_DIR/$name" "agent $h/$name"
      done
    fi
    prune_stale "$AGENTS_DIR"
  fi

  if [ -n "$SETTINGS_DEST" ] && [ -f "$HARNESSES_DIR/$h/settings.json" ]; then
    link_item "$HARNESSES_DIR/$h/settings.json" "$SETTINGS_DEST" "settings $h"
  fi

  if [ -n "$CLAUDE_MD_DEST" ] && [ -f "$HARNESSES_DIR/$h/CLAUDE.md" ]; then
    link_item "$HARNESSES_DIR/$h/CLAUDE.md" "$CLAUDE_MD_DEST" "CLAUDE.md $h"
  fi
done

[ "$FAIL" -eq 0 ]
