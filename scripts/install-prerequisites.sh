#!/usr/bin/env bash
# Installs the external tools the skills in this repo depend on: the GitHub CLI,
# jq, and the two gh extensions (gh-pr-review, gh-webhook). Every step checks
# first and is a no-op when the tool is already present, so re-running is safe.
#
# Usage: scripts/install-prerequisites.sh [--dry-run] [--skip-webhook]
set -uo pipefail

DRY_RUN=0
SKIP_WEBHOOK=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --skip-webhook) SKIP_WEBHOOK=1 ;;
    -h|--help)
      echo "usage: install-prerequisites.sh [--dry-run] [--skip-webhook]"
      exit 0
      ;;
    *) echo "error: unknown argument '$arg'" >&2; exit 1 ;;
  esac
done

FAIL=0

# Privileged commands go through $SUDO so this works both as root and as a
# normal user; empty when already root.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  fi
fi

# run <description> <command...> — honours --dry-run, records failures.
run() {
  local desc="$1"; shift
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would $desc: $*"
    return 0
  fi
  echo "$desc: $*"
  if ! "$@"; then
    echo "error: failed to $desc" >&2
    FAIL=1
    return 1
  fi
}

need_privilege() {
  if [ -n "$SUDO" ] || [ "$(id -u)" -eq 0 ]; then
    return 0
  fi
  echo "error: installing $1 needs root and sudo is not available; install it manually" >&2
  FAIL=1
  return 1
}

# ---------------------------------------------------------------- system packages

detect_manager() {
  for m in brew apt-get dnf pacman zypper; do
    if command -v "$m" >/dev/null 2>&1; then
      echo "$m"
      return 0
    fi
  done
  return 1
}

MANAGER="$(detect_manager)" || MANAGER=""

# The GitHub CLI is not in every distro's default repos. On apt systems without
# a candidate, add the official cli.github.com repo first (idempotent: skipped
# once the sources.list.d entry exists).
add_gh_apt_repo() {
  local list=/etc/apt/sources.list.d/github-cli.list
  local keyring=/etc/apt/keyrings/githubcli-archive-keyring.gpg

  if [ -f "$list" ]; then
    echo "github-cli apt repo already configured ($list)"
    return 0
  fi
  need_privilege "the github-cli apt repo" || return 1

  run "create keyring dir" $SUDO mkdir -p -m 755 /etc/apt/keyrings || return 1
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would fetch https://cli.github.com/packages/githubcli-archive-keyring.gpg -> $keyring"
    echo "would add $list and run apt-get update"
    return 0
  fi
  if ! curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | $SUDO tee "$keyring" >/dev/null; then
    echo "error: failed to fetch the github-cli signing key" >&2
    FAIL=1
    return 1
  fi
  run "set keyring permissions" $SUDO chmod go+r "$keyring" || return 1
  if ! printf 'deb [arch=%s signed-by=%s] https://cli.github.com/packages stable main\n' \
      "$(dpkg --print-architecture)" "$keyring" | $SUDO tee "$list" >/dev/null; then
    echo "error: failed to write $list" >&2
    FAIL=1
    return 1
  fi
  run "refresh apt package lists" $SUDO apt-get update || return 1
}

install_package() {
  local tool="$1" apt_name="$2" dnf_name="$3" pacman_name="$4"

  case "$MANAGER" in
    brew)
      run "install $tool" brew install "$apt_name"
      ;;
    apt-get)
      if [ "$tool" = "gh" ] && apt-cache policy gh 2>/dev/null | grep -q 'Candidate: (none)'; then
        add_gh_apt_repo || return 1
      fi
      need_privilege "$tool" || return 1
      run "install $tool" $SUDO apt-get install -y "$apt_name"
      ;;
    dnf)
      need_privilege "$tool" || return 1
      run "install $tool" $SUDO dnf install -y "$dnf_name"
      ;;
    pacman)
      need_privilege "$tool" || return 1
      run "install $tool" $SUDO pacman -S --needed --noconfirm "$pacman_name"
      ;;
    zypper)
      need_privilege "$tool" || return 1
      run "install $tool" $SUDO zypper install -y "$dnf_name"
      ;;
    *)
      echo "error: no supported package manager found; install $tool manually" >&2
      FAIL=1
      return 1
      ;;
  esac
}

check_tool() {
  local tool="$1"; shift
  if command -v "$tool" >/dev/null 2>&1; then
    echo "ok - $tool present ($("$tool" --version 2>/dev/null | head -1))"
    return 0
  fi
  echo "$tool missing"
  install_package "$tool" "$@"
}

check_tool gh gh gh github-cli
check_tool jq jq jq jq

# ------------------------------------------------------------------ gh extensions

if ! command -v gh >/dev/null 2>&1; then
  # In a dry run gh may simply not be installed yet; that is not a failure.
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "would install gh extensions once gh is installed and authenticated"
  else
    echo "skipping gh extensions: gh is not installed" >&2
    FAIL=1
  fi
elif ! gh auth status >/dev/null 2>&1; then
  echo "skipping gh extensions: gh is not authenticated — run 'gh auth login' first" >&2
  FAIL=1
else
  EXT_LIST="$(gh extension list 2>/dev/null)"

  install_extension() {
    local repo="$1" purpose="$2"
    if grep -qiF "$repo" <<<"$EXT_LIST"; then
      echo "ok - $repo present"
      return 0
    fi
    echo "$repo missing ($purpose)"
    run "install extension $repo" gh extension install "$repo"
  }

  install_extension agynio/gh-pr-review "inline PR review threads"
  if [ "$SKIP_WEBHOOK" -eq 0 ]; then
    install_extension cli/gh-webhook "push-style GitHub event forwarding"
  fi
fi

if [ "$DRY_RUN" -eq 1 ] && [ "$FAIL" -eq 0 ]; then
  echo "dry run complete — nothing was changed"
elif [ "$FAIL" -eq 0 ]; then
  echo "all prerequisites satisfied"
else
  echo "one or more prerequisites could not be installed" >&2
fi

[ "$FAIL" -eq 0 ]
