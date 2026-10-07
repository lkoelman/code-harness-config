# Zotero local API cheat sheet

For `zotero.py raw PATH key=value ...`. The local API serves a read-only subset of [Zotero Web API v3](https://www.zotero.org/support/dev/web_api/v3/basics) from the running Zotero desktop app (Zotero 7+). Verified against Zotero 10.0.4.

## Differences from the web API

- Base URL `http://127.0.0.1:23119/api/`. No API key.
- "My Library" is `users/0` (the real user ID also works). Group libraries: `groups/<groupID>`; list them with `users/0/groups`.
- Read-only: `POST`/`PUT`/`PATCH`/`DELETE` are refused (HTTP 428).
- `items/<attKey>/file` redirects (302) to a `file://` URL, and `items/<attKey>/file/view/url` returns that URL as text. Attachment JSON carries it in `links.enclosure.href`.
- `items/<attKey>/fulltext` returns `{"content", "indexedPages", "totalPages"}` (or `indexedChars`/`totalChars`); 404 if not indexed.
- `items?itemKey=A,B` also returns the items' child notes and attachments. `items/top?itemKey=A,B` returns only A and B.
- `tags?q=` ignores `q`; use `items/tags?q=` to filter tags.
- `limit` is not capped at 100 as on the web API, but large pages are slow.
- HTTP 403 means the local API is disabled: Zotero → Settings → Advanced → *Allow other applications on this computer to communicate with Zotero*.

## Endpoints (prefix `users/0/` or `groups/<id>/`)

| Path | Returns |
|---|---|
| `items` | All items, including child attachments and notes |
| `items/top` | Top-level items only |
| `items/<key>` | One item |
| `items/<key>/children` | Its attachments and notes |
| `items/<attKey>/fulltext` | Indexed full text |
| `items/<attKey>/file/view/url` | `file://` URL of the stored file |
| `items/trash` | Items in the trash |
| `items/tags`, `items/top/tags` | Tags on (top-level) items |
| `collections`, `collections/top` | All / top-level collections |
| `collections/<key>` | One collection |
| `collections/<key>/collections` | Its subcollections |
| `collections/<key>/items`, `collections/<key>/items/top` | Items in the collection |
| `searches`, `searches/<key>` | Saved searches (definitions only) |
| `searches/<key>/items` | Items matching a saved search |
| `tags` | All tags in the library |
| `fulltext?since=<version>` | `{attKey: version}` of attachments with indexed text |

## Query parameters

| Parameter | Values |
|---|---|
| `q` | Quick search: title, creators, year |
| `qmode` | `titleCreatorYear` (default) or `everything` (all fields + full text) |
| `tag` | `tag=A&tag=B` (AND), `tag=A || B` (OR), `tag=-A` (NOT) |
| `itemType` | e.g. `journalArticle`, `-attachment`, `book || bookSection` |
| `itemKey` | Comma-separated keys, max 50 |
| `since` | Only objects modified after this library version |
| `sort` | `dateAdded`, `dateModified`, `title`, `creator`, `itemType`, `date`, `publisher`, `publicationTitle`, `journalAbbreviation`, `language`, `accessDate`, `libraryCatalog`, `callNumber`, `rights`, `addedBy`, `numItems` |
| `direction` | `asc`, `desc` |
| `limit`, `start` | Paging. The response header `Total-Results` gives the total. |
| `format` | `json` (default), `keys`, `versions`, `bibtex`, `biblatex`, `ris`, `csljson`, `csv`, `mods`, `refer`, `rdf_bibliontology`, `rdf_dc`, `rdf_zotero`, `tei`, `wikipedia`, `bib` (formatted bibliography HTML) |
| `include` | With `format=json`: comma-separated `data`, `bib`, `citation`, or an export format such as `bibtex` |
| `style` | CSL style id for `bib`/`citation`, e.g. `apa`, `ieee`, `chicago-note-bibliography`, `nature` |
| `locale` | e.g. `en-US` |

Examples:

```bash
zotero raw users/0/items/top format=keys sort=dateAdded limit=5
zotero raw users/0/searches
zotero raw users/0/collections/R5MINMKC/collections
zotero raw users/0/items/K8ZP2VAD include=bibtex
```

## Upstream references

- Web API v3 basics: <https://www.zotero.org/support/dev/web_api/v3/basics>
- Local API announcement: <https://groups.google.com/g/zotero-dev/c/ElvHhIFAXrY/m/fA7SKKwsAgAJ>
- Local API tests (ground truth for supported behaviour): <https://github.com/zotero/zotero/blob/main/test/tests/server_localAPITest.js>
- Item types and fields schema: <https://github.com/zotero/zotero-schema> (served at <https://api.zotero.org/schema>)
- Pyzotero (Python client for the web API): <https://github.com/urschrei/pyzotero>
