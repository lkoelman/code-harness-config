---
name: pdf2md-docling
description: Convert PDF documents to Markdown with the docling CLI (run through uvx), keeping headings, tables and images (exported as PNG files referenced from the Markdown). Use when the user asks to convert a PDF to Markdown, extract a PDF's content as Markdown, turn a report or paper into .md for reading or for feeding into context, or mentions docling. Not for editing, merging, splitting or filling PDFs.
---

## Default command

```bash
uvx --from docling docling convert <file.pdf> --image-export-mode referenced [--output <dir>]
```

- `uvx --from docling` runs the `docling` CLI from uv's cache. Nothing is installed into the project or a venv.
- `--image-export-mode referenced` is the default for this skill. docling's own default is `embedded`, which inlines every image as base64 and makes the Markdown unreadable. Always pass this flag unless the user asks for a different mode (see Options).
- `--output <dir>` sets the output directory. docling's default is the current directory. Pass `--output` when the user names a location; otherwise keep the default.
- Quote paths that contain spaces.

Output for `Final Report.pdf`:

```
<output>/Final Report.md
<output>/Final Report_artifacts/image_000000_<hash>.png   # one PNG per picture
```

Image links in the Markdown are relative and URL-encoded (`![Image](Final%20Report_artifacts/image_000000_….png)`), so keep the `.md` file and its `_artifacts/` folder together when moving them.

## Options

Add these only when the input or the user's request calls for them:

| Flag | Use when |
|---|---|
| `--image-export-mode placeholder` | The user wants text only and no image files. Each image becomes an `<!-- image -->` marker. |
| `--image-export-mode embedded` | The user wants one self-contained `.md` file with base64 images. |
| `--no-ocr` | The PDF is born-digital (selectable text). Skips OCR and runs faster. |
| `--ocr-mode full_page` | The PDF is scanned or its text layer is broken. Replaces the existing text with OCR output. (`--force-ocr` is deprecated.) |
| `--ocr-lang <langs>` | OCR on non-English text. Comma-separated; BCP-47 tags need an `iso:` prefix, e.g. `--ocr-lang iso:zh-Hans`. |
| `--page-range <a-b>` | Convert only some pages, e.g. `--page-range 1-4` (1-based). |
| `--table-mode fast` | Many or large tables and speed matters more than structure accuracy. Default is `accurate`. |
| `--enrich-formula` | Math-heavy documents. Converts formulas to LaTeX. Slower. |
| `--pdf-password <pw>` | The PDF is password-protected. |
| `--pipeline vlm` | The standard pipeline produced poor output on a hard layout. Uses a vision-language model (default `granite_docling`). Much slower; offer it, don't default to it. |
| `-q` | Suppress per-file progress logs. |

`source` also accepts a directory (converts every supported file in it) or a URL. Run `uvx --from docling docling convert --help` for the full option list.

## First run

On the first run, `uvx` downloads docling and its dependencies (including torch), and docling downloads layout, table and OCR models (into `~/.cache/huggingface` and uv's cache). Expect this to take minutes. Run the command with a long timeout, or in the background, and wait for it to finish instead of re-running it. Later runs start in seconds; conversion time then scales with page count.

docling logs to stderr at INFO level. A run succeeded when it exits with status 0; without `-q` it also prints `Finished converting document <name> in <N> sec.` per file.

## After converting

- Report the path of the `.md` file and of the `_artifacts/` folder.
- Read the Markdown only if the user wants its content (a summary, a question answered, an excerpt). Don't paste a long document into the chat.
- docling's heading levels and reading order are inferred from layout and are sometimes wrong (for example a title placed after the first section). If the user will use the Markdown directly, skim the headings and mention obvious problems; don't silently rewrite the content.

## Failures

- `uvx: command not found`: uv is not installed. Tell the user to install it (https://docs.astral.sh/uv/getting-started/installation/) and stop.
- Model download fails (network or proxy errors from `huggingface` or `modelscope`): report the error. A retry after the network is fixed resumes from the cache.
- With several inputs, docling continues past a failed file by default. Report which files failed and which succeeded.
