# Code Harness Config

Configuration and tooling for code harnesses

## Contents

- **OpenCode Configuration**: Custom agents and skills for OpenCode
- **Gemini CLI Configuration**: Custom agents and skills for Gemini CLI

---

# OpenCode Configuration

This repository provides custom agents and skills for OpenCode. Installation is managed using [GNU Stow](https://www.gnu.org/software/stow/), which creates symlinks from `~/.opencode/` to this repository.

## Prerequisites

### 1. Install GNU Stow

For example, on Debian/Ubuntu: `sudo apt-get install stow`.

### 2. Install GitHub CLI

See the [official installation guide](https://github.com/cli/cli/blob/trunk/docs/install_linux.md).

### 3. Install GitHub CLI Extension (for PR reviews)

```bash
gh extension install agynio/gh-pr-review
```

## Installation

### Option 1: Using the Installation Script (Recommended)

```bash
./scripts/install-opencode-config.sh
```

This script will:
- Check if GNU Stow is installed
- Detect and remove any existing manual symlinks (with confirmation)
- Install the configuration using Stow
- Verify the installation

### Option 2: Manual Installation with Stow

```bash
# From the repository root
stow -v -R -t ~ opencode
```

Flags explained:
- `-v`: Verbose output
- `-R`: Restow (reinstall) - safe to use for updates
- `-t ~`: Set target directory to home directory

## Verifying Installation

Check that the symlinks were created correctly:

```bash
ls -la ~/.opencode/
```

You should see:
- `agents/` → symlink to this repository
- `skills/` → symlink to this repository

List installed agents and skills:

```bash
ls ~/.opencode/agents/
ls ~/.opencode/skills/
```

## Updating

To update after pulling new changes:

```bash
git pull
./install-opencode-config.sh
# or
stow -v -R -t ~ opencode
```

The `-R` (restow) flag safely updates symlinks.

## Uninstallation

### Option 1: Using the Uninstallation Script

```bash
./scripts/uninstall-opencode-config.sh
```

This script will:
- Remove all stow-managed symlinks
- Optionally remove the entire `~/.opencode/` directory if empty

### Option 2: Manual Uninstallation with Stow

```bash
stow -v -D -t ~ opencode
```

The `-D` flag removes symlinks.

## Troubleshooting

### Conflict with existing files

If you have existing files in `~/.opencode/`, Stow will report conflicts and refuse to install. You have two options:

1. **Backup and remove existing files:**
   ```bash
   mv ~/.opencode ~/.opencode.backup
   ./install-opencode-config.sh
   ```

2. **Manually resolve conflicts** by removing or moving specific conflicting files.

### Existing manual symlinks

If you previously installed using manual symlinks (e.g., `ln -s`), the installation script will detect them and offer to remove them. Alternatively, remove them manually:

```bash
rm ~/.opencode/agents ~/.opencode/skills
./install-opencode-config.sh
```

### Stow reports "target is not owned by stow"

This means there are existing files/directories that weren't created by Stow. Remove them as described above.

### Check Stow dry-run

To see what Stow would do without making changes:

```bash
stow -n -v -R -t ~ opencode
```

The `-n` flag performs a dry-run.

## What Gets Installed

After installation, `~/.opencode/` will contain:

- **agents/**: Custom OpenCode agent configurations
  - `autoplan.md` - Plans code changes before execution
  - `search-grounding.md` - Web search with grounded results
  - `search-grounding-subagent.md` - Search agent for subagent use

- **skills/**: Custom OpenCode skills
  - `github-cli/` - GitHub CLI integration skill

All files are symlinked to this repository, so updates are automatically reflected after pulling changes and restowing.

---

# Gemini CLI Configuration

This repository provides custom agents and skills for Gemini CLI. Installation is managed using [GNU Stow](https://www.gnu.org/software/stow/), which creates symlinks from `~/.gemini/` to this repository.

## Installation

### 1. Install GNU Stow

If not already installed (see OpenCode Configuration above).

### 2. Install Configuration with Stow

```bash
# From the repository root
stow -v -R -t ~ gemini-cli
```

### 3. Verify Installation

Check that the symlinks were created correctly:

```bash
ls -la ~/.gemini/agents/
ls -la ~/.gemini/skills/
```

### 4. Reload Skills

After installation, reload the skills in your interactive Gemini CLI session to enable them:

```bash
/skills reload
```

## What Gets Installed

- **agents/**: Custom Gemini CLI agent configurations
  - `autoplan.md` - Plans code changes before execution
  - `plan-writer.md` - Writes plans for changes

- **skills/**: Custom Gemini CLI skills
  - `github-cli/` - GitHub CLI integration skill

All files are symlinked to this repository.
