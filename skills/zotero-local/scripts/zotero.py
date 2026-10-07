#!/usr/bin/env python3
"""CLI for the Zotero local API (http://127.0.0.1:23119/api/).

Reads need no authorization. Writes (Zotero 10+) need a local API key, which
`authorize` obtains from Zotero and stores per Zotero server ID in
${XDG_CONFIG_HOME:-~/.config}/zotero-local/auth.json ($ZOTERO_LOCAL_API_KEY
overrides it).

Standard library only. Run with --help, or <command> --help, for usage.

Exit codes: 0 success; 1 bad input, item not found, version conflict or
read-only library; 2 Zotero not reachable or its local API disabled;
3 no valid write key, or authorization denied.
"""

import argparse
import html
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
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
NO_KEY_HINT = "no valid write key for this Zotero: run `zotero.py authorize` and click 'Always Allow' in Zotero"
NO_WRITE_HINT = "Zotero did not send a Zotero-Server-ID header; writing needs Zotero 10 or later"
# Item fields `update` refuses; each has a dedicated command or must not change.
UPDATE_FORBIDDEN = {"creators", "tags", "collections", "note", "relations", "key", "version", "itemType", "parentItem", "deleted"}


class CliError(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


# ----------------------------------------------------------------- HTTP layer


class Client:
    def __init__(self, base_url, library, dry_run=False):
        self.base = base_url.rstrip("/")
        self.lib = library_prefix(library)
        self.dry_run = dry_run
        self._server_id = None

    def request(self, path, params=None, method="GET", body=None, headers=None, timeout=60):
        """Send one request. Returns (status, headers, body text); raises CliError if unreachable.

        `body`, if given, is sent as JSON.
        """
        url = self.base + path
        if params:
            url += "?" + urlencode(params, doseq=True)
        all_headers = {"Zotero-API-Version": "3", "Zotero-Allowed-Request": "1", **(headers or {})}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            all_headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, headers=all_headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.status, resp.headers, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.headers, e.read().decode("utf-8", "replace")
        except TimeoutError:
            raise CliError("no response from Zotero at %s within %d s" % (self.base, timeout), 2)
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

    def server_id(self):
        """This Zotero instance's Zotero-Server-ID ('' if it sends none, i.e. before Zotero 10)."""
        if self._server_id is None:
            _, headers, _ = self.request("/api/")
            self._server_id = headers.get("Zotero-Server-ID") or ""
        return self._server_id

    def require_server_id(self):
        sid = self.server_id()
        if not sid:
            raise CliError(NO_WRITE_HINT)
        return sid

    def write(self, method, path, body, what):
        """Send an authorized write. Returns the write report for POST, else None.

        With --dry-run, prints the request instead and returns None.
        """
        if self.dry_run:
            print("DRY RUN: %s %s" % (method, path))
            print(json.dumps(body, indent=2, ensure_ascii=False))
            return None
        sid = self.require_server_id()
        key = load_key(sid)
        if not key:
            raise CliError(NO_KEY_HINT, 3)
        status, _, text = self.request(path, method=method, body=body, headers={"Zotero-Server-ID": sid, "Zotero-API-Key": key})
        if status == 401:
            raise CliError("%s (Zotero said: %s)" % (NO_KEY_HINT, text.strip()), 3)
        if status == 403:
            if "Write access denied" in text:
                raise CliError("library %s is read-only for you" % self.lib)
            raise CliError(ENABLE_HINT, 2)
        if status == 404:
            raise CliError("not found: %s" % what)
        if status == 412:
            raise CliError("%s changed in Zotero since it was read; re-run the command" % what)
        if not 200 <= status < 300:
            raise CliError("HTTP %d from %s %s: %s" % (status, method, path, text.strip()[:500]))
        if method != "POST":
            return None
        report = json.loads(text)
        for failure in report.get("failed", {}).values():
            raise CliError("writing %s failed (HTTP %s): %s" % (what, failure.get("code"), failure.get("message")))
        return report

    def patch_item(self, key, entry, changes):
        """PATCH `changes` onto the item `entry` (as fetched by item()). Returns False, without
        sending anything, if every field already holds its new value."""
        data = entry["data"]
        if all(same_value(data.get(k), v) for k, v in changes.items()):
            return False
        self.write("PATCH", "%s/items/%s" % (self.lib, key), {**changes, "version": data["version"]}, "item %s" % key)
        return True


def library_prefix(library):
    if library == "user":
        return "/api/users/0"
    m = re.match(r"^group:(\d+)$", library)
    if not m:
        raise CliError("invalid --library %r: use 'user' or 'group:<id>'" % library)
    return "/api/groups/" + m.group(1)


def check_key(key):
    if not KEY_RE.match(key):
        raise CliError("invalid key %r: expected 8 characters A-Z/0-9" % key)
    return key


def same_value(current, new):
    """Field equality that treats absent, empty and false as one value."""
    return current == new or (not current and not new)


# ------------------------------------------------------------------ write keys


def auth_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "zotero-local", "auth.json")


def load_keys():
    try:
        with open(auth_path()) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}
    except ValueError:
        raise CliError("cannot parse %s; delete it and run authorize" % auth_path())


def load_key(server_id):
    return os.environ.get("ZOTERO_LOCAL_API_KEY") or load_keys().get(server_id, {}).get("key")


def save_key(server_id, entry):
    keys = load_keys()
    keys[server_id] = entry
    path = auth_path()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(keys, f, indent=2)
    # os.open's mode only applies when it creates the file.
    os.chmod(path, 0o600)


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


def text_to_html(text):
    """Plain text to note HTML: blank-line-separated paragraphs become <p>, newlines <br>."""
    paras = [p.strip() for p in re.split(r"\n\s*\n", text.strip()) if p.strip()]
    return "\n".join("<p>%s</p>" % html.escape(p, quote=False).replace("\n", "<br>") for p in paras)


def note_html(args):
    """Note HTML from --html, --text or --file (.html/.htm used as-is, '-' reads stdin)."""
    if args.html is not None:
        return args.html
    if args.text is not None:
        return text_to_html(args.text)
    if args.file == "-":
        content = sys.stdin.read()
    else:
        try:
            with open(args.file, encoding="utf-8") as f:
                content = f.read()
        except OSError as e:
            raise CliError("cannot read %s: %s" % (args.file, e.strerror))
    return content if args.file.lower().endswith((".html", ".htm")) else text_to_html(content)


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
        # Notes have no title field: show the first line of their text.
        "title": data.get("title") or html_to_text(data.get("note")).split("\n")[0][:80],
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


def emit_actions(client, args, rows):
    """Print (action, key) rows of a write command; nothing under --dry-run."""
    if client.dry_run:
        return
    if args.json:
        emit_json([{"action": a, "key": k} for a, k in rows])
        return
    for action, key in rows:
        print("%s\t%s" % (action, key))


# ------------------------------------------------------------------- commands


def cmd_ping(client, args):
    status, root_headers, _ = client.request("/api/")
    if status == 404:
        raise CliError("Zotero at %s has no local API; it needs Zotero 7 or later" % client.base, 2)
    version = root_headers.get("X-Zotero-Version") or "unknown"
    headers, _ = client.get("%s/items/top" % client.lib, {"limit": 1, "format": "keys"})
    total = int(headers.get("Total-Results") or 0)
    sid = root_headers.get("Zotero-Server-ID")
    if not sid:
        write = "not supported (needs Zotero 10 or later)"
    elif os.environ.get("ZOTERO_LOCAL_API_KEY"):
        write = "key from $ZOTERO_LOCAL_API_KEY"
    elif load_key(sid):
        write = "key stored for this Zotero (server %s)" % sid
    else:
        write = "not authorized (run authorize)"
    if args.json:
        emit_json({"ok": True, "zoteroVersion": version, "library": client.lib, "topLevelItems": total, "write": write})
    else:
        print("Zotero %s local API OK; %s has %d top-level items" % (version, client.lib, total))
        print("write: %s" % write)


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


# ------------------------------------------------------------- write commands


def cmd_authorize(client, args):
    sid = client.require_server_id()
    print("Waiting for approval: click 'Always Allow' in the Zotero window ('Allow' gives a single-use key).", file=sys.stderr)
    status, headers, text = client.request(
        "/api/local/authorize", method="POST", body={"appName": args.app_name}, headers={"Zotero-Server-ID": sid}, timeout=300
    )
    if status == 403:
        if "denied" in text:
            raise CliError("authorization denied in Zotero", 3)
        raise CliError(ENABLE_HINT, 2)
    if status == 404:
        raise CliError(NO_WRITE_HINT)
    if status == 429:
        raise CliError("too many authorization requests; retry in %s s" % headers.get("Retry-After", "60"))
    if status != 200:
        raise CliError("HTTP %d from /api/local/authorize: %s" % (status, text.strip()[:500]))
    resp = json.loads(text)
    remember = bool(resp.get("remember"))
    save_key(sid, {
        "key": resp["key"],
        "remember": remember,
        "appName": args.app_name,
        "createdAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    })
    if not remember:
        print("warning: 'Allow' gave a single-use key, which the next write consumes. "
              "Run authorize again and click 'Always Allow' for a persistent key.", file=sys.stderr)
    if args.json:
        emit_json({"authorized": True, "serverID": sid, "remember": remember, "keyFile": auth_path()})
    else:
        print("authorized\tserver %s; key stored in %s" % (sid, auth_path()))


def cmd_add_note(client, args):
    parent = check_key(args.key) if args.key else None
    collections = [check_key(c) for c in args.collection or []]
    if parent and collections:
        raise CliError("--collection only applies to standalone notes; a child note lives under its parent item")
    note = {"itemType": "note", "note": note_html(args)}
    if parent:
        note["parentItem"] = parent
    if args.tag:
        note["tags"] = [{"tag": t} for t in args.tag]
    if collections:
        note["collections"] = collections
    report = client.write("POST", "%s/items" % client.lib, [note], "note")
    if report:
        emit_actions(client, args, [("created", report["success"]["0"])])


def cmd_edit_note(client, args):
    key = check_key(args.key)
    entry = client.item(key)
    item_type = entry["data"].get("itemType")
    if item_type != "note":
        raise CliError("%s is not a note (itemType %s)" % (key, item_type))
    new = note_html(args)
    if args.append:
        new = (entry["data"].get("note") or "") + new
    changed = client.patch_item(key, entry, {"note": new})
    emit_actions(client, args, [("updated" if changed else "unchanged", key)])


def cmd_tag(client, args):
    keys = [check_key(k) for k in args.keys]
    if not args.add and not args.remove:
        raise CliError("give --add and/or --remove")
    rows = []
    for key in keys:
        entry = client.item(key)
        tags = [t for t in entry["data"].get("tags", []) if t["tag"] not in args.remove]
        have = {t["tag"] for t in tags}
        for t in args.add:
            if t not in have:
                tags.append({"tag": t})
                have.add(t)
        changed = client.patch_item(key, entry, {"tags": tags})
        rows.append(("updated" if changed else "unchanged", key))
    emit_actions(client, args, rows)


def cmd_collect(client, args):
    keys = [check_key(k) for k in args.keys]
    coll = check_key(args.add or args.remove)
    if args.add:
        client.get("%s/collections/%s" % (client.lib, coll), what="collection %s in %s" % (coll, client.lib))
    rows = []
    for key in keys:
        entry = client.item(key)
        if entry["data"].get("parentItem"):
            raise CliError("%s is a child item (note or attachment); only top-level items can be in collections" % key)
        collections = entry["data"].get("collections", [])
        if args.add:
            collections = collections + ([] if coll in collections else [coll])
        else:
            collections = [c for c in collections if c != coll]
        changed = client.patch_item(key, entry, {"collections": collections})
        rows.append(("updated" if changed else "unchanged", key))
    emit_actions(client, args, rows)


def cmd_create_collection(client, args):
    body = {"name": args.name}
    if args.parent:
        body["parentCollection"] = check_key(args.parent)
    report = client.write("POST", "%s/collections" % client.lib, [body], "collection %r" % args.name)
    if report:
        emit_actions(client, args, [("created", report["success"]["0"])])


def cmd_update(client, args):
    key = check_key(args.key)
    changes = {}
    for kv in args.fields:
        if "=" not in kv:
            raise CliError("%r is not field=value" % kv)
        field, value = kv.split("=", 1)
        changes[field] = value
    forbidden = sorted(set(changes) & UPDATE_FORBIDDEN)
    if forbidden:
        raise CliError("update cannot set %s; use tag, collect, edit-note or trash instead" % ", ".join(forbidden))
    entry = client.item(key)
    item_type = entry["data"]["itemType"]
    _, fields = client.get_json("/api/itemTypeFields", {"itemType": item_type}, what="fields of itemType %s" % item_type)
    valid = {f["field"] for f in fields}
    unknown = [f for f in changes if f not in valid]
    if unknown:
        raise CliError("not a field of itemType %s: %s (valid: %s)" % (item_type, ", ".join(unknown), ", ".join(sorted(valid))))
    changed = client.patch_item(key, entry, changes)
    emit_actions(client, args, [("updated" if changed else "unchanged", key)])


def cmd_trash(client, args):
    """trash and restore: set the item's 'deleted' flag. Never erases."""
    keys = [check_key(k) for k in args.keys]
    trash = args.command == "trash"
    rows = []
    for key in keys:
        changed = client.patch_item(key, client.item(key), {"deleted": trash})
        rows.append((("trashed" if trash else "restored") if changed else "unchanged", key))
    emit_actions(client, args, rows)


# ------------------------------------------------------------------------ CLI


def build_parser():
    p = argparse.ArgumentParser(prog="zotero.py", description="Read-only client for the Zotero local API.")
    p.add_argument("--base-url", default=os.environ.get("ZOTERO_LOCAL_URL", DEFAULT_BASE_URL), help="default: $ZOTERO_LOCAL_URL or %(default)s")
    p.add_argument("--library", default="user", help="'user' (default) or 'group:<id>'")
    p.add_argument("--json", action="store_true", help="print JSON instead of text")
    p.add_argument("--dry-run", action="store_true", help="print write requests instead of sending them")
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

    # Write commands (Zotero 10+, after `authorize`).
    s = sub.add_parser("authorize", help="ask Zotero for a write key (the user must click 'Always Allow')")
    s.add_argument("--app-name", default="zotero-local skill", help="name shown in Zotero's prompt")
    s.set_defaults(func=cmd_authorize)

    def add_content_args(s):
        g = s.add_mutually_exclusive_group(required=True)
        g.add_argument("--text", help="plain text; blank lines separate paragraphs")
        g.add_argument("--html", help="note HTML")
        g.add_argument("--file", help="read content from a file ('-' for stdin); .html/.htm is used as HTML")

    s = sub.add_parser("add-note", help="add a child note to an item, or a standalone note")
    s.add_argument("key", nargs="?", help="parent item key; omit for a standalone note")
    add_content_args(s)
    s.add_argument("--tag", action="append", help="tag for the note; repeatable")
    s.add_argument("--collection", action="append", help="collection key for a standalone note; repeatable")
    s.set_defaults(func=cmd_add_note)

    s = sub.add_parser("edit-note", help="replace or append to a note's content")
    s.add_argument("key", help="note key")
    add_content_args(s)
    s.add_argument("--append", action="store_true", help="append instead of replacing")
    s.set_defaults(func=cmd_edit_note)

    s = sub.add_parser("tag", help="add or remove tags on items")
    s.add_argument("keys", nargs="+")
    s.add_argument("--add", action="append", default=[], help="repeatable")
    s.add_argument("--remove", action="append", default=[], help="repeatable")
    s.set_defaults(func=cmd_tag)

    s = sub.add_parser("collect", help="add items to, or remove them from, a collection")
    s.add_argument("keys", nargs="+")
    g = s.add_mutually_exclusive_group(required=True)
    g.add_argument("--add", metavar="COLLECTION")
    g.add_argument("--remove", metavar="COLLECTION")
    s.set_defaults(func=cmd_collect)

    s = sub.add_parser("create-collection", help="create a collection")
    s.add_argument("name")
    s.add_argument("--parent", help="parent collection key")
    s.set_defaults(func=cmd_create_collection)

    s = sub.add_parser("update", help="set metadata fields of an item")
    s.add_argument("key")
    s.add_argument("fields", nargs="+", metavar="field=value", help="'field=' clears the field")
    s.set_defaults(func=cmd_update)

    for name, help_text in (("trash", "move items to Zotero's trash"), ("restore", "restore items from Zotero's trash")):
        s = sub.add_parser(name, help=help_text)
        s.add_argument("keys", nargs="+")
        s.set_defaults(func=cmd_trash)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        client = Client(args.base_url, args.library, dry_run=args.dry_run)
        args.func(client, args)
    except CliError as e:
        print("zotero.py: %s" % e, file=sys.stderr)
        return e.code
    except BrokenPipeError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
