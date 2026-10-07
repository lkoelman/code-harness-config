# Zotero local API cheat sheet

For `zotero.py raw PATH key=value ...`, and for understanding what the write commands send. The local API serves [Zotero Web API v3](https://www.zotero.org/support/dev/web_api/v3/basics) from the running Zotero desktop app: reads since Zotero 7, writes since Zotero 10. Verified against Zotero 10.0.4 (`server_localAPI.js` in the app's `omni.ja`).

## Differences from the web API

- Base URL `http://127.0.0.1:23119/api/`. No API key.
- "My Library" is `users/0` (the real user ID also works). Group libraries: `groups/<groupID>`; list them with `users/0/groups`.
- Writes need a local API key from `POST /api/local/authorize` (see [Writes](#writes)); reads need none.
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

## Writes

Every `POST`/`PUT`/`PATCH`/`DELETE` needs:
- `Zotero-Server-ID: <id>`, copied from the `Zotero-Server-ID` header of any response. Missing → 428; another instance's ID → 412.
- `Zotero-API-Key: <key>` (or `?key=`, or `Authorization: Bearer <key>`). Missing, unknown or already-consumed → 401.
- `Content-Type: application/json` for JSON bodies.

The `zotero.py` write commands also send `Zotero-Allowed-Request: 1`, as Zotero's own test suite does.

**Authorize:** `POST /api/local/authorize` with body `{"appName": "<name>"}` and the `Zotero-Server-ID` header opens a modal in Zotero. The request blocks until the user clicks:
- **Always Allow** → 200 `{"key": "<32 chars>", "remember": true}`.
- **Allow** → the same with `"remember": false`; the first successful write consumes the key.
- **Deny** → 403 `{"denied": true}`.
- More than 5 requests per minute → 429 with `Retry-After`.

Keys live in `<Zotero profile>/localAPIKeys.json`; the user can clear them in Zotero → Settings → Advanced.

**Endpoints and semantics:**

| Request | Effect |
|---|---|
| `POST items`, `POST collections`, `POST searches` | JSON array of up to 50 new objects (or keyed objects to update). Always HTTP 200 with a write report: `{"successful": {"0": obj}, "success": {"0": key}, "unchanged": {}, "failed": {"0": {"key", "code", "message"}}}`. Check `failed`. |
| `PATCH items/<key>` (also collections, searches) | Merges top-level fields onto the object. Arrays (`tags`, `collections`, `creators`) are replaced whole. 204. |
| `PUT items/<key>` | Replaces the whole object. 204. |
| `DELETE items/<key>`, `DELETE items?itemKey=A,B` | **Erases permanently**, bypassing the trash. `zotero.py` never does this; it PATCHes `{"deleted": true}` instead, which moves the item to the trash. |
| `DELETE tags?tag=A \|\| B` | Removes tags from every item. Needs `If-Unmodified-Since-Version` with the library version. |
| `PUT items/<attKey>/fulltext`, `POST fulltext` | Sets indexed full text. |
| `POST items/<attKey>/file` → `POST local/uploads/<uploadKey>` → `POST items/<attKey>/file` with `upload=<uploadKey>` | Uploads a file into an existing imported-file attachment (form-encoded `md5`, `filename`, `filesize`, `mtime` in ms; `If-None-Match: *` for a new file). |

**Concurrency:** writes to an existing object need its version, either as `"version": <n>` in the JSON (from `data.version` of a GET) or as the `If-Unmodified-Since-Version` header. A stale version → 412. Local versions are unrelated to web API versions.

**Validation:** objects are applied with `fromJSON(json, {strict: false})`, so an unknown field may be dropped without an error. Check field names against `GET /api/itemTypeFields?itemType=<type>` first (`zotero.py update` does).

Item types and fields: `GET /api/itemTypes`, `/api/itemTypeFields?itemType=<type>`, `/api/itemTypeCreatorTypes?itemType=<type>`, `/api/creatorFields`, `/api/schema`.

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
