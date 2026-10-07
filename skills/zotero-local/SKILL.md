---
name: zotero-local
description: Search and read the user's local Zotero library through the Zotero local HTTP API (127.0.0.1:23119) — find papers by title, author, tag, collection or full text; read metadata, abstracts, notes and indexed PDF text; get local PDF file paths; export BibTeX/RIS/CSL-JSON; format citations. Use whenever the user mentions Zotero, "my library", "my papers", "my references", asks what they have saved on a topic, wants a citation or BibTeX entry for a paper they own, or wants to read or summarize a paper from their Zotero collection.
---

## When to use me

The user wants something out of **their own Zotero library**: find a paper, list what they saved on a topic or in a collection, read its abstract, notes or full text, get the PDF path, export BibTeX, or format a citation.

Read-only. The local API refuses writes, so this skill cannot add items, edit tags or create notes. Not for searching the web for papers the user has not saved.

## Bundled script

`scripts/zotero.py` (Python 3, standard library only) sits next to this SKILL.md. If the harness told you the path it loaded this skill from, use that, otherwise:

```bash
SKILL_DIR=$(for d in "$HOME/.claude/skills" "$HOME/.codex/skills" "$HOME/.gemini/skills" \
                     "$HOME/.config/opencode/skills" "$HOME/.pi/agent/skills"; do
              [ -f "$d/zotero-local/SKILL.md" ] && { echo "$d/zotero-local"; break; }
            done)
zotero() { python3 "$SKILL_DIR/scripts/zotero.py" "$@"; }
```

**Preflight, once per session:** `zotero ping`. Exit 2 means Zotero is not running or its local API is off; relay the printed fix to the user and stop. Do not try to start Zotero yourself.

## Commands

Global options go **before** the command: `--json` (structured output), `--library group:<id>` (a group library instead of "My Library"; list groups with `zotero raw users/0/groups`), `--base-url` (default `$ZOTERO_LOCAL_URL` or `http://127.0.0.1:23119`).

| Command | Output |
|---|---|
| `search [QUERY] [--everything] [--tag T]... [--type T] [--collection KEY] [--all-items] [--sort F --direction asc\|desc] [--limit N] [--start N]` | One line per item: `KEY  itemType  creators  year  title`, then `# N of TOTAL shown`. Top-level items only unless `--all-items`. Default `--limit 25`. |
| `get KEY...` | All non-empty fields, abstract, attachments (key, content type, local path) and notes (key, first line). |
| `notes KEY` | The item's child notes as plain text. |
| `fulltext KEY [--max-chars N]` | Text Zotero indexed from the item's PDF/EPUB/HTML attachment. KEY may be the parent or the attachment. |
| `path KEY` | `attKey  contentType  /local/path` per attachment — pass the path to your file-reading tool for figures and layout the indexed text loses. |
| `export KEY... [--format bibtex\|biblatex\|ris\|csljson\|...]` | Export text, default BibTeX. |
| `cite KEY... [--style apa\|ieee\|chicago-note-bibliography\|...] [--locale en-US]` | In-text citation and bibliography entry, plain text. |
| `collections [--tree]` | `KEY  name (numItems)`; `--tree` indents subcollections. |
| `tags [FILTER]` | `tag  (numItems)`, filtered by substring. |
| `raw PATH [key=value ...]` | Body of any GET under `/api/`, e.g. `raw users/0/searches`. For endpoints and parameters the commands above do not cover; see `references/local-api.md`. |

Item keys are 8 characters, `A-Z0-9` (e.g. `K8ZP2VAD`); every command that takes keys gets them from `search` output. `export` and `cite` take top-level item keys only; for an attachment or note key, use its parent's key.

## Search tips

- `QUERY` matches title, creators and year. Add `--everything` to also match all fields and the indexed full text of PDFs. It is slower and returns more noise, so try without it first.
- `--tag` repeated is AND; `--tag 'A || B'` is OR; `--tag '-A'` excludes. Same syntax for `--type`, e.g. `--type 'journalArticle || preprint'`, `--type -attachment`.
- Find a collection's key with `collections --tree`, then `search --collection KEY`.
- Recent additions: `search --sort dateAdded --limit 10`.
- A title often appears twice (e.g. a preprint and a webpage snapshot). Prefer the entry whose `itemType` matches what the user asked for, or whichever has the PDF (`path KEY`).

## Workflows

**"What do I have on X?"** → `search "X"`; if few hits, `search "X" --everything`; then `get` the promising keys and summarize from title + abstract. Cite keys so the user can find them.

**"Summarize / answer a question from paper P"** → `search` to get the key → `fulltext KEY --max-chars 40000`. If the output says `truncated`, re-run without `--max-chars`, redirect to a file in your temp/scratch directory, and read that file in parts. If the command prints `no indexed full text`, fall back to `path KEY` and read the PDF directly.

**"BibTeX for these"** → `search` each, then `export K1 K2 ...` in one call.

**"What did I note about P?"** → `notes KEY`.

## Troubleshooting

| Message (stderr) | Cause | Fix |
|---|---|---|
| `Zotero is not running or not reachable` | Zotero desktop app is closed, or a different port | Ask the user to open Zotero. |
| `local API is disabled` | Setting off | Zotero → Settings → Advanced → check *Allow other applications on this computer to communicate with Zotero*. |
| `has no local API; it needs Zotero 7 or later` | Zotero 6 or older | Ask the user to upgrade Zotero. |
| `not found: item KEY` | Wrong key, or the item is in a group library | Re-run `search`, or add `--library group:<id>`. |
| `no indexed full text` | PDF not indexed yet | Use `path KEY` and read the PDF. |
