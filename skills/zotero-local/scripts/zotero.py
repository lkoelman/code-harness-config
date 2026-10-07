#!/usr/bin/env python3
"""Read-only CLI for the Zotero local API (http://127.0.0.1:23119/api/).

Standard library only. Run with --help, or <command> --help, for usage.

Exit codes: 0 success; 1 bad input or item not found; 2 Zotero not reachable
or its local API disabled.
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from html.parser import HTMLParser
from urllib.parse import urlencode, urlsplit

DEFAULT_BASE_URL = "http://127.0.0.1:23119"
PAGE_SIZE = 100
KEY_RE = re.compile(r"^[A-Z0-9]{8}$")
ENABLE_HINT = (
    "Zotero's local API is disabled. Enable it in Zotero -> Settings -> Advanced -> "
    "'Allow other applications on this computer to communicate with Zotero'."
)
# Fields `get` prints first, in this order; the rest follow in API order.
LEAD_FIELDS = ["title", "itemType", "creators", "date"]
SKIP_FIELDS = {"key", "version", "relations", "abstractNote", "note"}
FULLTEXT_TYPES = ("application/pdf", "application/epub+zip", "text/html")


class CliError(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


# ----------------------------------------------------------------- HTTP layer


class Client:
    def __init__(self, base_url, library):
        self.base = base_url.rstrip("/")
        self.lib = library_prefix(library)

    def request(self, path, params=None):
        """GET base+path. Returns (status, headers, body text); raises CliError if unreachable."""
        url = self.base + path
        if params:
            url += "?" + urlencode(params, doseq=True)
        req = urllib.request.Request(url, headers={"Zotero-API-Version": "3"})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                return resp.status, resp.headers, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.headers, e.read().decode("utf-8", "replace")
        except (urllib.error.URLError, OSError) as e:
            reason = getattr(e, "reason", e)
            raise CliError("Zotero is not running or not reachable at %s (%s)" % (self.base, reason), 2)

    def get(self, path, params=None, what=None):
        """GET and check the status; returns (headers, body text)."""
        status, headers, body = self.request(path, params)
        if status == 403:
            raise CliError(ENABLE_HINT, 2)
        if status == 404:
            raise CliError("not found: %s" % (what or path))
        if not 200 <= status < 300:
            raise CliError("HTTP %d from %s: %s" % (status, path, body.strip()[:500]))
        return headers, body

    def get_json(self, path, params=None, what=None):
        headers, body = self.get(path, params, what)
        return headers, json.loads(body)

    def paged(self, path, params=None, limit=None, start=0):
        """Fetch up to `limit` results (all if None) in PAGE_SIZE pages. Returns (results, total)."""
        results, total = [], None
        while limit is None or len(results) < limit:
            size = PAGE_SIZE if limit is None else min(PAGE_SIZE, limit - len(results))
            headers, batch = self.get_json(path, {**(params or {}), "start": start, "limit": size})
            if headers.get("Total-Results") is not None:
                total = int(headers["Total-Results"])
            results.extend(batch)
            start += len(batch)
            if len(batch) < size or (total is not None and start >= total):
                break
        return results, total if total is not None else len(results)

    def item(self, key):
        return self.get_json("%s/items/%s" % (self.lib, key), what="item %s in %s" % (key, self.lib))[1]

    def children(self, key, params=None):
        return self.get_json("%s/items/%s/children" % (self.lib, key), params, what="item %s in %s" % (key, self.lib))[1]


def library_prefix(library):
    if library == "user":
        return "/api/users/0"
    m = re.match(r"^group:(\d+)$", library)
    if not m:
        raise CliError("invalid --library %r: use 'user' or 'group:<id>'" % library)
    return "/api/groups/" + m.group(1)


def check_key(key):
    if not KEY_RE.match(key):
        raise CliError("invalid item key %r: expected 8 characters A-Z/0-9" % key)
    return key


# -------------------------------------------------------------------- helpers


class _TextExtractor(HTMLParser):
    BLOCK = {"p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "table"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []

    def handle_starttag(self, tag, attrs):
        if tag in self.BLOCK:
            self.parts.append("\n")
        if tag == "li":
            self.parts.append("- ")

    def handle_endtag(self, tag):
        if tag in self.BLOCK:
            self.parts.append("\n")

    def handle_data(self, data):
        self.parts.append(data)


def html_to_text(html):
    p = _TextExtractor()
    p.feed(html or "")
    p.close()
    lines = [line.strip() for line in "".join(p.parts).splitlines()]
    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip()


def file_path(entry):
    """Local filesystem path of an attachment, or None if it has no local file."""
    href = entry.get("links", {}).get("enclosure", {}).get("href", "")
    if not href.startswith("file://"):
        return None
    return urllib.request.url2pathname(urlsplit(href).path)


def format_creator(c):
    name = c.get("name") or ", ".join(x for x in (c.get("lastName"), c.get("firstName")) if x)
    return "%s (%s)" % (name, c.get("creatorType", "author"))


def summary(entry):
    data, meta = entry.get("data", {}), entry.get("meta", {})
    return {
        "key": entry.get("key"),
        "itemType": data.get("itemType"),
        # Group libraries wrap names in Unicode bidi isolation marks (U+2068/U+2069).
        "creators": meta.get("creatorSummary", "").replace("\u2068", "").replace("\u2069", ""),
        "year": (meta.get("parsedDate") or "")[:4],
        "title": data.get("title") or data.get("note", "")[:80],
    }


def child_summary(entry):
    data = entry.get("data", {})
    if data.get("itemType") == "note":
        return {"key": entry["key"], "itemType": "note", "text": html_to_text(data.get("note"))}
    return {
        "key": entry["key"],
        "itemType": data.get("itemType"),
        "title": data.get("title"),
        "contentType": data.get("contentType"),
        "linkMode": data.get("linkMode"),
        "path": file_path(entry),
        "url": data.get("url"),
    }


def attachments_of(client, key):
    """The item itself if it is an attachment, else its attachment children."""
    entry = client.item(key)
    if entry["data"].get("itemType") == "attachment":
        return entry, [entry]
    return entry, [c for c in client.children(key) if c["data"].get("itemType") == "attachment"]


def emit_json(obj):
    print(json.dumps(obj, indent=2, ensure_ascii=False))


# ------------------------------------------------------------------- commands


def cmd_ping(client, args):
    status, root_headers, _ = client.request("/api/")
    if status == 404:
        raise CliError("Zotero at %s has no local API; it needs Zotero 7 or later" % client.base, 2)
    version = root_headers.get("X-Zotero-Version") or "unknown"
    headers, _ = client.get("%s/items/top" % client.lib, {"limit": 1, "format": "keys"})
    total = int(headers.get("Total-Results") or 0)
    if args.json:
        emit_json({"ok": True, "zoteroVersion": version, "library": client.lib, "topLevelItems": total})
    else:
        print("Zotero %s local API OK; %s has %d top-level items" % (version, client.lib, total))


def cmd_search(client, args):
    if args.collection:
        path = "%s/collections/%s/items" % (client.lib, check_key(args.collection))
    else:
        path = "%s/items" % client.lib
    if not args.all_items:
        path += "/top"
    params = {}
    if args.query:
        params["q"] = args.query
    if args.everything:
        params["qmode"] = "everything"
    if args.tag:
        params["tag"] = args.tag
    if args.type:
        params["itemType"] = args.type
    if args.sort:
        params["sort"] = args.sort
        params["direction"] = args.direction
    items, total = client.paged(path, params, limit=args.limit, start=args.start)
    rows = [summary(i) for i in items]
    if args.json:
        emit_json({"total": total, "start": args.start, "items": rows})
        return
    for r in rows:
        print("\t".join([r["key"], r["itemType"] or "", r["creators"], r["year"], r["title"]]))
    print("# %d of %d shown (start %d)" % (len(rows), total, args.start))


def cmd_get(client, args):
    keys = [check_key(k) for k in args.keys]
    out = []
    for key in keys:
        entry = client.item(key)
        kids = [] if entry["data"].get("itemType") in ("note", "attachment") else client.children(key)
        out.append({"key": key, "meta": entry.get("meta", {}), "data": entry["data"], "children": [child_summary(c) for c in kids]})
    if args.json:
        emit_json(out if len(out) > 1 else out[0])
        return
    for n, rec in enumerate(out):
        if n:
            print("\n" + "-" * 60)
        print_item(rec)


def print_item(rec):
    data = rec["data"]
    print("Key: %s" % rec["key"])
    for field in LEAD_FIELDS + [f for f in data if f not in LEAD_FIELDS]:
        value = data.get(field)
        if field in SKIP_FIELDS or value in (None, "", [], {}):
            continue
        if field == "creators":
            value = "; ".join(format_creator(c) for c in value)
        elif field == "tags":
            value = "; ".join(t["tag"] for t in value)
        elif isinstance(value, list):
            value = ", ".join(str(v) for v in value)
        print("%s: %s" % (field, value))
    if data.get("note"):
        print("note:\n%s" % html_to_text(data["note"]))
    if data.get("abstractNote"):
        print("abstractNote: %s" % data["abstractNote"])
    atts = [c for c in rec["children"] if c["itemType"] == "attachment"]
    notes = [c for c in rec["children"] if c["itemType"] == "note"]
    if atts:
        print("Attachments:")
        for a in atts:
            print("  %s\t%s\t%s" % (a["key"], a["contentType"] or a["linkMode"], a["path"] or a["url"] or a["title"]))
    if notes:
        print("Notes:")
        for nt in notes:
            first = next((line for line in nt["text"].splitlines() if line.strip()), "")
            print("  %s\t%s" % (nt["key"], first[:100]))


def cmd_notes(client, args):
    key = check_key(args.key)
    notes = [child_summary(c) for c in client.children(key, {"itemType": "note"})]
    if args.json:
        emit_json(notes)
        return
    if not notes:
        print("# no notes on %s" % key)
    for nt in notes:
        print("=== note %s ===\n%s\n" % (nt["key"], nt["text"]))


def cmd_fulltext(client, args):
    key = check_key(args.key)
    entry = client.item(key)
    if entry["data"].get("itemType") == "attachment":
        att = key
    else:
        href = entry.get("links", {}).get("attachment", {}).get("href", "")
        att = href.rsplit("/", 1)[-1] if href else None
        if not att:
            kids = [c for c in client.children(key) if c["data"].get("contentType") in FULLTEXT_TYPES]
            if not kids:
                raise CliError("no PDF, EPUB or HTML attachment on %s" % key)
            att = kids[0]["key"]
    status, _, body = client.request("%s/items/%s/fulltext" % (client.lib, att))
    if status == 404:
        raise CliError("no indexed full text for attachment %s (Zotero has not indexed it)" % att)
    if status == 403:
        raise CliError(ENABLE_HINT, 2)
    if status != 200:
        raise CliError("HTTP %d fetching full text for %s" % (status, att))
    ft = json.loads(body)
    content = ft.get("content", "")
    truncated = args.max_chars is not None and len(content) > args.max_chars
    if args.json:
        emit_json({"attachment": att, **ft, "content": content[: args.max_chars] if truncated else content, "truncated": truncated})
        return
    if truncated:
        print(content[: args.max_chars])
        print("\n[... truncated: showing %d of %d chars of attachment %s]" % (args.max_chars, len(content), att))
    else:
        print(content)


def cmd_path(client, args):
    _, atts = attachments_of(client, check_key(args.key))
    rows = [child_summary(a) for a in atts]
    if args.json:
        emit_json(rows)
        return
    for r in rows:
        print("%s\t%s\t%s" % (r["key"], r["contentType"] or r["linkMode"], r["path"] or r["url"] or "-"))


def cmd_export(client, args):
    keys = [check_key(k) for k in args.keys]
    # /items?itemKey= also returns the items' child notes and attachments; /items/top does not.
    _, body = client.get("%s/items/top" % client.lib, {"itemKey": ",".join(keys), "format": args.format})
    sys.stdout.write(body if body.endswith("\n") else body + "\n")


def cmd_cite(client, args):
    keys = [check_key(k) for k in args.keys]
    params = {"itemKey": ",".join(keys), "include": "citation,bib", "style": args.style}
    if args.locale:
        params["locale"] = args.locale
    _, entries = client.get_json("%s/items/top" % client.lib, params)
    rows = [{"key": e["key"], "citation": html_to_text(e.get("citation")), "bib": html_to_text(e.get("bib"))} for e in entries]
    if args.json:
        emit_json(rows)
        return
    for r in rows:
        print("%s\t%s\n%s\n" % (r["key"], r["citation"], r["bib"]))


def cmd_collections(client, args):
    cols, _ = client.paged("%s/collections" % client.lib)
    rows = [
        {"key": c["key"], "name": c["data"]["name"], "parent": c["data"].get("parentCollection") or None, "numItems": c.get("meta", {}).get("numItems")}
        for c in cols
    ]
    rows.sort(key=lambda r: r["name"].lower())
    if args.json:
        emit_json(rows)
        return
    if not args.tree:
        for r in rows:
            print("%s  %s (%s)" % (r["key"], r["name"], r["numItems"]))
        return
    keys = {r["key"] for r in rows}
    by_parent = {}
    for r in rows:
        by_parent.setdefault(r["parent"] if r["parent"] in keys else None, []).append(r)

    def walk(parent, depth):
        for r in by_parent.get(parent, []):
            print("%s%s  %s (%s)" % ("  " * depth, r["key"], r["name"], r["numItems"]))
            walk(r["key"], depth + 1)

    walk(None, 0)


def cmd_tags(client, args):
    params = {"q": args.filter} if args.filter else {}
    # The local API ignores q on /tags but honours it on /items/tags.
    tags, _ = client.paged("%s/items/tags" % client.lib, params)
    rows = [{"tag": t["tag"], "numItems": t.get("meta", {}).get("numItems")} for t in tags]
    if args.json:
        emit_json(rows)
        return
    for r in rows:
        print("%s\t(%s)" % (r["tag"], r["numItems"]))


def cmd_raw(client, args):
    path = args.path if args.path.startswith("/api/") else "/api/" + args.path.lstrip("/")
    params = []
    for kv in args.params:
        if "=" not in kv:
            raise CliError("raw parameter %r is not key=value" % kv)
        params.append(tuple(kv.split("=", 1)))
    _, body = client.get(path, params)
    sys.stdout.write(body if body.endswith("\n") else body + "\n")


# ------------------------------------------------------------------------ CLI


def build_parser():
    p = argparse.ArgumentParser(prog="zotero.py", description="Read-only client for the Zotero local API.")
    p.add_argument("--base-url", default=os.environ.get("ZOTERO_LOCAL_URL", DEFAULT_BASE_URL), help="default: $ZOTERO_LOCAL_URL or %(default)s")
    p.add_argument("--library", default="user", help="'user' (default) or 'group:<id>'")
    p.add_argument("--json", action="store_true", help="print JSON instead of text")
    sub = p.add_subparsers(dest="command", required=True)

    s = sub.add_parser("ping", help="check that Zotero and its local API are reachable")
    s.set_defaults(func=cmd_ping)

    s = sub.add_parser("search", help="search items (top-level by default)")
    s.add_argument("query", nargs="?", help="matches title, creators, year (and full text with --everything)")
    s.add_argument("--everything", action="store_true", help="also search full text and all fields (qmode=everything)")
    s.add_argument("--tag", action="append", help="tag filter; repeat for AND, 'A || B' for OR, '-A' for NOT")
    s.add_argument("--type", help="itemType filter, e.g. journalArticle, '-attachment', 'book || bookSection'")
    s.add_argument("--collection", help="restrict to this collection key")
    s.add_argument("--all-items", action="store_true", help="include child attachments and notes")
    s.add_argument("--sort", help="dateAdded, dateModified, title, creator, itemType, date, publisher, ...")
    s.add_argument("--direction", choices=["asc", "desc"], default="desc")
    s.add_argument("--limit", type=int, default=25)
    s.add_argument("--start", type=int, default=0)
    s.set_defaults(func=cmd_search)

    s = sub.add_parser("get", help="full metadata, attachments and notes of items")
    s.add_argument("keys", nargs="+")
    s.set_defaults(func=cmd_get)

    s = sub.add_parser("notes", help="child notes of an item as plain text")
    s.add_argument("key")
    s.set_defaults(func=cmd_notes)

    s = sub.add_parser("fulltext", help="indexed full text of an item's PDF/EPUB/HTML attachment")
    s.add_argument("key", help="parent item key or attachment key")
    s.add_argument("--max-chars", type=int)
    s.set_defaults(func=cmd_fulltext)

    s = sub.add_parser("path", help="local file paths of an item's attachments")
    s.add_argument("key")
    s.set_defaults(func=cmd_path)

    s = sub.add_parser("export", help="export items as bibtex, biblatex, ris, csljson, ...")
    s.add_argument("keys", nargs="+")
    s.add_argument("--format", default="bibtex")
    s.set_defaults(func=cmd_export)

    s = sub.add_parser("cite", help="formatted citation and bibliography entry")
    s.add_argument("keys", nargs="+")
    s.add_argument("--style", default="apa", help="CSL style id, e.g. apa, ieee, chicago-note-bibliography")
    s.add_argument("--locale", help="e.g. en-US")
    s.set_defaults(func=cmd_cite)

    s = sub.add_parser("collections", help="list collections")
    s.add_argument("--tree", action="store_true", help="indent subcollections under their parent")
    s.set_defaults(func=cmd_collections)

    s = sub.add_parser("tags", help="list tags")
    s.add_argument("filter", nargs="?", help="substring filter")
    s.set_defaults(func=cmd_tags)

    s = sub.add_parser("raw", help="GET any local API path and print the body")
    s.add_argument("path", help="path under /api, e.g. users/0/searches")
    s.add_argument("params", nargs="*", help="key=value query parameters")
    s.set_defaults(func=cmd_raw)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        client = Client(args.base_url, args.library)
        args.func(client, args)
    except CliError as e:
        print("zotero.py: %s" % e, file=sys.stderr)
        return e.code
    except BrokenPipeError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
