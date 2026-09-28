#!/usr/bin/env bash
# Builds and symlinks skills/agents (and, for pi-agent, settings.json) into
# each harness's config directory, one symlink per item so unrelated content
# already in those directories is left untouched.
#
# --project <path> installs into <path>/<PROJECT_*_DIR> (relative paths from
# the harness .conf) instead of $HOME; settings.json and CLAUDE.md are never
# installed into a project. --skills/--output-style narrow the install to
# those categories (both: the union); --exclude-skills drops skills from
# whatever else installs. --copy copies instead of symlinking.
#
# Usage: scripts/install.sh (--all|<harness>...) [--project <path>]
#          [--skills a,b] [--exclude-skills a,b] [--output-style]
#          [--copy] [--dry-run] [--force]
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
HARNESSES_DIR="$REPO/harnesses"
BUILD_DIR="$REPO/build"

USAGE="usage: install.sh (--all|<harness>...) [--project <path>] [--skills a,b] [--exclude-skills a,b] [--output-style] [--copy] [--dry-run] [--force]"

DRY_RUN=0
FORCE=0
ALL=0
COPY=0
OUTPUT_STYLE_ONLY=0
PROJECT=""
ONLY_SKILLS=""
EXCLUDE_SKILLS=""
declare -a TARGETS=()

# need_value <flag> <value-or-empty>: a value flag must not be last or be
# followed by another flag.
need_value() {
  case "${2-}" in
    ""|--*) echo "error: $1 requires a value" >&2; exit 1 ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --all) ALL=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    --copy) COPY=1 ;;
    --output-style) OUTPUT_STYLE_ONLY=1 ;;
    --project) need_value "$1" "${2-}"; PROJECT="$2"; shift ;;
    --skills) need_value "$1" "${2-}"; ONLY_SKILLS="$2"; shift ;;
    --exclude-skills) need_value "$1" "${2-}"; EXCLUDE_SKILLS="$2"; shift ;;
    --*) echo "error: unknown flag '$1'" >&2; exit 1 ;;
    *) TARGETS+=("$1") ;;
  esac
  shift
done

# Read-loop instead of `mapfile`, which macOS's bash 3.2 does not have.
# For the same reason arrays that may be empty are expanded through the
# ${arr[@]+...} / ${arr[*]-} guards: bash 3.2 treats an empty array as unset
# and `set -u` would abort on a bare "${arr[@]}".
declare -a KNOWN_HARNESSES=()
while IFS= read -r conf_name; do
  [ -n "$conf_name" ] && KNOWN_HARNESSES+=("$conf_name")
done < <(
  for f in "$HARNESSES_DIR"/*.conf; do
    [ -e "$f" ] || continue
    basename "$f" .conf
  done
)

if [ "$ALL" -eq 1 ]; then
  TARGETS=(${KNOWN_HARNESSES[@]+"${KNOWN_HARNESSES[@]}"})
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "$USAGE" >&2
  echo "known harnesses: ${KNOWN_HARNESSES[*]-}" >&2
  exit 1
fi

for h in "${TARGETS[@]}"; do
  found=0
  for k in ${KNOWN_HARNESSES[@]+"${KNOWN_HARNESSES[@]}"}; do [ "$k" = "$h" ] && found=1; done
  if [ "$found" -eq 0 ]; then
    echo "error: unknown harness '$h' (known: ${KNOWN_HARNESSES[*]-})" >&2
    exit 1
  fi
done

if [ -n "$PROJECT" ]; then
  if [ ! -d "$PROJECT" ]; then
    echo "error: --project $PROJECT is not a directory" >&2
    exit 1
  fi
  if [ ! -e "$PROJECT/.git" ] && [ ! -d "$PROJECT/.claude" ]; then
    echo "error: $PROJECT has no .git or .claude/ (not a project root)" >&2
    exit 1
  fi
  PROJECT="$(cd "$PROJECT" && pwd -P)"
fi

# in_list <name> <comma-list>
in_list() {
  case ",$2," in *",$1,"*) return 0 ;; esac
  return 1
}

for name in $(tr ',' ' ' <<<"$ONLY_SKILLS $EXCLUDE_SKILLS"); do
  if [ ! -f "$REPO/skills/$name/SKILL.md" ]; then
    echo "error: unknown skill '$name' (no skills/$name/SKILL.md)" >&2
    exit 1
  fi
done

# Category gates: with no selector everything installs; --skills and
# --output-style each select their own category.
DO_SKILLS=1; DO_AGENTS=1; DO_OUTPUT_STYLES=1; DO_OTHER=1
if [ -n "$ONLY_SKILLS" ] || [ "$OUTPUT_STYLE_ONLY" -eq 1 ]; then
  DO_AGENTS=0; DO_OTHER=0
  [ -n "$ONLY_SKILLS" ] || DO_SKILLS=0
  [ "$OUTPUT_STYLE_ONLY" -eq 1 ] || DO_OUTPUT_STYLES=0
fi

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

# copy_item <source-in-build-or-repo> <dest-path> <label>
# Like link_item, but places a real copy. An existing copy identical to the
# source is left alone, so re-running is a no-op.
copy_item() {
  local src="$1" dest="$2" label="$3"

  if [ -L "$dest" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "would replace symlink $dest with a copy of $label"
      return 0
    fi
    rm -f "$dest"
    cp -R "$src" "$dest"
    echo "copied $label -> $dest (replaced symlink)"
    return 0
  fi

  if [ -e "$dest" ]; then
    if diff -rq "$src" "$dest" >/dev/null 2>&1; then
      return 0
    fi
    if [ "$FORCE" -ne 1 ]; then
      echo "error: $dest exists and differs from $label (refusing to clobber without --force)" >&2
      FAIL=1
      return 1
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "would back up existing $dest and replace with a copy of $label"
      return 0
    fi
    local backup; backup="$(backup_path "$dest")"
    mv "$dest" "$backup"
    echo "backed up existing $dest -> $backup"
    cp -R "$src" "$dest"
    echo "copied $label -> $dest"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would copy $label -> $dest"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  cp -R "$src" "$dest"
  echo "copied $label -> $dest"
}

# link_item <source-in-build-or-repo> <dest-path> <label>
# With --copy, delegates to copy_item.
link_item() {
  local src="$1" dest="$2" label="$3"

  if [ "$COPY" -eq 1 ]; then
    copy_item "$src" "$dest" "$label"
    return
  fi

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

# Removes symlinks in $1 whose target points into $2 (default $REPO/build/)
# but no longer resolves to anything (leftover from a renamed/removed
# skill, agent, or output style).
prune_stale() {
  local dir="$1" prefix="${2:-$REPO/build/}" link raw
  [ -d "$dir" ] || return 0
  for link in "$dir"/*; do
    [ -L "$link" ] || continue
    [ -e "$link" ] && continue
    raw="$(readlink "$link")"
    case "$raw" in
      "$prefix"*)
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
  OUTPUT_STYLES_DIR=""
  PROJECT_SKILLS_DIR=""
  PROJECT_AGENTS_DIR=""
  PROJECT_OUTPUT_STYLES_DIR=""
  # shellcheck disable=SC1090
  source "$HARNESSES_DIR/$h.conf"

  if [ -n "$PROJECT" ]; then
    SKILLS_DIR="${PROJECT_SKILLS_DIR:+$PROJECT/$PROJECT_SKILLS_DIR}"
    AGENTS_DIR="${PROJECT_AGENTS_DIR:+$PROJECT/$PROJECT_AGENTS_DIR}"
    OUTPUT_STYLES_DIR="${PROJECT_OUTPUT_STYLES_DIR:+$PROJECT/$PROJECT_OUTPUT_STYLES_DIR}"
    SETTINGS_DEST=""
    CLAUDE_MD_DEST=""
    if [ -z "$SKILLS_DIR$AGENTS_DIR$OUTPUT_STYLES_DIR" ]; then
      echo "skipping $h: no project paths in $h.conf"
      continue
    fi
  fi

  if [ -n "$SKILLS_DIR" ] && [ "$DO_SKILLS" -eq 1 ]; then
    [ "$DRY_RUN" -eq 1 ] || mkdir -p "$SKILLS_DIR"
    if [ -d "$BUILD_DIR/$h/skills" ]; then
      for item in "$BUILD_DIR/$h/skills"/*; do
        [ -e "$item" ] || continue
        name="$(basename "$item")"
        if [ -n "$ONLY_SKILLS" ] && ! in_list "$name" "$ONLY_SKILLS"; then continue; fi
        if in_list "$name" "$EXCLUDE_SKILLS"; then continue; fi
        link_item "$item" "$SKILLS_DIR/$name" "skill $h/$name"
      done
    fi
    prune_stale "$SKILLS_DIR"
  fi

  if [ -n "$AGENTS_DIR" ] && [ "$DO_AGENTS" -eq 1 ]; then
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

  if [ -n "$SETTINGS_DEST" ] && [ "$DO_OTHER" -eq 1 ] && [ -f "$HARNESSES_DIR/$h/settings.json" ]; then
    link_item "$HARNESSES_DIR/$h/settings.json" "$SETTINGS_DEST" "settings $h"
  fi

  if [ -n "$CLAUDE_MD_DEST" ] && [ "$DO_OTHER" -eq 1 ] && [ -f "$HARNESSES_DIR/$h/CLAUDE.md" ]; then
    link_item "$HARNESSES_DIR/$h/CLAUDE.md" "$CLAUDE_MD_DEST" "CLAUDE.md $h"
  fi

  if [ -n "$OUTPUT_STYLES_DIR" ] && [ "$DO_OUTPUT_STYLES" -eq 1 ]; then
    [ "$DRY_RUN" -eq 1 ] || mkdir -p "$OUTPUT_STYLES_DIR"
    if [ -d "$HARNESSES_DIR/$h/output-styles" ]; then
      for item in "$HARNESSES_DIR/$h/output-styles"/*; do
        [ -e "$item" ] || continue
        name="$(basename "$item")"
        link_item "$item" "$OUTPUT_STYLES_DIR/$name" "output style $h/$name"
      done
    fi
    prune_stale "$OUTPUT_STYLES_DIR" "$REPO/harnesses/$h/output-styles/"
  fi
done

[ "$FAIL" -eq 0 ]
