"""Tests for skills/zotero-local/scripts/zotero.py.

Each test starts a mock Zotero local API on a random port and runs the CLI
as a subprocess against it, so nothing here talks to a real Zotero. Fixture
shapes are trimmed from real Zotero 10 local API responses.

Run: python3 -I scripts/test_zotero_local.py -v
"""

import http.server
import json
import os
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from urllib.parse import parse_qs, urlsplit

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(REPO, "skills", "zotero-local", "scripts", "zotero.py")

LIB = "/api/users/0"


def item(key, title, item_type="preprint", creator_summary="Lange et al.", date="2025-09-17", **data):
    return {
        "key": key,
        "meta": {"creatorSummary": creator_summary, "parsedDate": date, "numChildren": 0},
        "links": {},
        "data": {"key": key, "itemType": item_type, "title": title, "date": date, **data},
    }


PARENT = item(
    "K8ZP2VAD",
    "ShinkaEvolve: Towards Open-Ended And Sample-Efficient Program Evolution",
    DOI="10.48550/arXiv.2509.19349",
    url="http://arxiv.org/abs/2509.19349",
    abstractNote="We introduce ShinkaEvolve.",
    creators=[
        {"firstName": "Robert Tjarko", "lastName": "Lange", "creatorType": "author"},
        {"name": "Sakana AI", "creatorType": "author"},
    ],
    tags=[{"tag": "Computer Science - Machine Learning", "type": 1}],
    collections=["R5MINMKC"],
)
PARENT["links"]["attachment"] = {
    "href": "http://localhost:23119/api/users/3262785/items/BESV9IZ5",
    "type": "application/json",
    "attachmentType": "application/pdf",
}

PDF = {
    "key": "BESV9IZ5",
    "meta": {},
    "links": {
        "enclosure": {
            "href": "file:///Users/me/Zotero/storage/BESV9IZ5/Lange%20et%20al.%20-%202025.pdf",
            "type": "application/pdf",
        }
    },
    "data": {
        "key": "BESV9IZ5",
        "itemType": "attachment",
        "parentItem": "K8ZP2VAD",
        "linkMode": "imported_url",
        "contentType": "application/pdf",
        "filename": "Lange et al. - 2025.pdf",
        "title": "Full Text PDF",
    },
}

NOTE = {
    "key": "62UPL4XJ",
    "meta": {},
    "links": {},
    "data": {
        "key": "62UPL4XJ",
        "itemType": "note",
        "parentItem": "K8ZP2VAD",
        "note": "<div><h1>My summary</h1><p>Uses <b>islands</b> &amp; novelty.</p></div>",
    },
}


class MockZotero(http.server.ThreadingHTTPServer):
    """Serves canned responses.

    Records every request twice: as (path, query dict) in `requests`, and with
    method, headers and decoded body in `log`.
    """

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.routes = {}
        self.requests = []
        self.log = []

    def route(self, path, body, status=200, headers=None, content_type="application/json", method="GET"):
        """body may be a callable taking (query, request body) and returning (body, headers)."""
        self.routes[(method, path)] = (status, body, headers or {}, content_type)


class Handler(http.server.BaseHTTPRequestHandler):
    def _handle(self):
        parts = urlsplit(self.path)
        query = parse_qs(parts.query)
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        try:
            req_body = json.loads(raw) if raw else None
        except ValueError:
            req_body = raw
        self.server.requests.append((parts.path, query))
        self.server.log.append(
            # Header names lowercased: HTTP treats them case-insensitively, and urllib sends "Zotero-server-id".
            {"method": self.command, "path": parts.path, "query": query, "headers": {k.lower(): v for k, v in self.headers.items()}, "body": req_body}
        )
        route = self.server.routes.get((self.command, parts.path))
        if route is None:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"Not found")
            return
        status, body, headers, content_type = route
        if callable(body):
            body, extra = body(query, req_body)
            headers = {**headers, **extra}
        if not isinstance(body, str):
            body = json.dumps(body)
        payload = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        for k, v in headers.items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(payload)

    do_GET = do_POST = do_PATCH = do_PUT = do_DELETE = _handle

    def log_message(self, *args):
        pass


class ZoteroCliTest(unittest.TestCase):
    def setUp(self):
        self.server = MockZotero()
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = "http://127.0.0.1:%d" % self.server.server_address[1]
        self.config = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.config.cleanup()

    def run_cli(self, *args, base=None, env_extra=None):
        env = {k: v for k, v in os.environ.items() if k not in ("ZOTERO_LOCAL_URL", "ZOTERO_LOCAL_API_KEY")}
        env["XDG_CONFIG_HOME"] = self.config.name
        env.update(env_extra or {})
        return subprocess.run(
            [sys.executable, "-I", CLI, "--base-url", base or self.base, *args],
            capture_output=True,
            text=True,
            env=env,
            timeout=30,
        )

    def paths(self):
        return [p for p, _ in self.server.requests]

    def query_for(self, path):
        for p, q in self.server.requests:
            if p == path:
                return q
        self.fail("no request to %s; got %s" % (path, self.paths()))

    # ------------------------------------------------------------------ ping

    def test_ping_reports_version_and_count(self):
        self.server.route("/api/", "Nothing to see here.", headers={"X-Zotero-Version": "10.0.4"}, content_type="text/plain")
        self.server.route(LIB + "/items/top", [], headers={"Total-Results": "1706"})
        r = self.run_cli("ping")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("10.0.4", r.stdout)
        self.assertIn("1706", r.stdout)

    def test_ping_when_zotero_not_running(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        r = self.run_cli("ping", base="http://127.0.0.1:%d" % port)
        self.assertEqual(r.returncode, 2)
        self.assertIn("not running", r.stderr)

    def test_ping_when_local_api_disabled(self):
        self.server.route("/api/", "Nothing to see here.", content_type="text/plain")
        self.server.route(LIB + "/items/top", "Local API is not enabled", status=403, content_type="text/plain")
        r = self.run_cli("ping")
        self.assertEqual(r.returncode, 2)
        self.assertIn("local API", r.stderr)

    # ---------------------------------------------------------------- search

    def test_search_builds_query_and_prints_lines(self):
        self.server.route(LIB + "/items/top", [PARENT], headers={"Total-Results": "9"})
        r = self.run_cli(
            "search", "evolve", "--everything", "--tag", "A", "--tag", "B || C", "--type", "preprint", "--limit", "5"
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        q = self.query_for(LIB + "/items/top")
        self.assertEqual(q["q"], ["evolve"])
        self.assertEqual(q["qmode"], ["everything"])
        self.assertEqual(q["tag"], ["A", "B || C"])
        self.assertEqual(q["itemType"], ["preprint"])
        self.assertEqual(q["limit"], ["5"])
        self.assertIn("K8ZP2VAD", r.stdout)
        self.assertIn("Lange et al.", r.stdout)
        self.assertIn("2025", r.stdout)
        self.assertIn("ShinkaEvolve", r.stdout)
        self.assertIn("1 of 9", r.stdout)

    def test_search_in_collection_and_all_items(self):
        self.server.route(LIB + "/collections/R5MINMKC/items/top", [PARENT], headers={"Total-Results": "1"})
        self.server.route(LIB + "/items", [PARENT, PDF], headers={"Total-Results": "2"})
        r = self.run_cli("search", "--collection", "R5MINMKC")
        self.assertEqual(r.returncode, 0, r.stderr)
        r = self.run_cli("search", "x", "--all-items")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(LIB + "/collections/R5MINMKC/items/top", self.paths())
        self.assertIn(LIB + "/items", self.paths())

    def test_search_shows_note_as_one_line_of_text(self):
        note = json.loads(json.dumps(NOTE))
        note["data"]["note"] = '<div data-schema-version="9"><p>First line</p>\n<p>second</p></div>'
        self.server.route(LIB + "/items", [note], headers={"Total-Results": "1"})
        r = self.run_cli("search", "--all-items")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.splitlines()[0], "62UPL4XJ\tnote\t\t\tFirst line")

    def test_search_pages_past_100(self):
        def page(q, _body):
            start = int(q.get("start", ["0"])[0])
            limit = int(q["limit"][0])
            n = min(limit, 150 - start)
            return [item("K%07d" % (start + i), "T%d" % (start + i)) for i in range(n)], {"Total-Results": "500"}

        self.server.route(LIB + "/items/top", page)
        r = self.run_cli("search", "--limit", "150")
        self.assertEqual(r.returncode, 0, r.stderr)
        starts = [q.get("start", ["0"])[0] for p, q in self.server.requests]
        self.assertEqual(starts, ["0", "100"])
        self.assertIn("150 of 500", r.stdout)

    # ------------------------------------------------------------------- get

    def test_get_prints_fields_and_children(self):
        self.server.route(LIB + "/items/K8ZP2VAD", PARENT)
        self.server.route(LIB + "/items/K8ZP2VAD/children", [PDF, NOTE])
        r = self.run_cli("get", "K8ZP2VAD")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("ShinkaEvolve: Towards", r.stdout)
        self.assertIn("10.48550/arXiv.2509.19349", r.stdout)
        self.assertIn("Lange, Robert Tjarko", r.stdout)
        self.assertIn("Sakana AI", r.stdout)
        self.assertIn("Computer Science - Machine Learning", r.stdout)
        self.assertIn("/Users/me/Zotero/storage/BESV9IZ5/Lange et al. - 2025.pdf", r.stdout)
        self.assertIn("62UPL4XJ", r.stdout)
        self.assertIn("My summary", r.stdout)

    def test_get_missing_item(self):
        r = self.run_cli("get", "ZZZZZZZZ")
        self.assertEqual(r.returncode, 1)
        self.assertIn("ZZZZZZZZ", r.stderr)

    def test_invalid_key_makes_no_request(self):
        r = self.run_cli("get", "../x")
        self.assertEqual(r.returncode, 1)
        self.assertIn("invalid", r.stderr.lower())
        self.assertEqual(self.server.requests, [])

    # ------------------------------------------------------------- fulltext

    def test_fulltext_resolves_attachment_and_truncates(self):
        self.server.route(LIB + "/items/K8ZP2VAD", PARENT)
        self.server.route(LIB + "/items/BESV9IZ5/fulltext", {"content": "0123456789abcdef", "indexedPages": 1, "totalPages": 1})
        r = self.run_cli("fulltext", "K8ZP2VAD", "--max-chars", "10")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("0123456789", r.stdout)
        self.assertNotIn("abcdef", r.stdout)
        self.assertIn("truncated", r.stdout)

    def test_fulltext_on_attachment_key(self):
        self.server.route(LIB + "/items/BESV9IZ5", PDF)
        self.server.route(LIB + "/items/BESV9IZ5/fulltext", {"content": "pdf text"})
        r = self.run_cli("fulltext", "BESV9IZ5")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "pdf text")

    def test_fulltext_not_indexed(self):
        self.server.route(LIB + "/items/BESV9IZ5", PDF)
        r = self.run_cli("fulltext", "BESV9IZ5")
        self.assertEqual(r.returncode, 1)
        self.assertIn("no indexed full text", r.stderr)

    # ------------------------------------------------------------------ path

    def test_path_lists_local_files(self):
        self.server.route(LIB + "/items/K8ZP2VAD", PARENT)
        self.server.route(LIB + "/items/K8ZP2VAD/children", [PDF, NOTE])
        r = self.run_cli("path", "K8ZP2VAD")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "BESV9IZ5\tapplication/pdf\t/Users/me/Zotero/storage/BESV9IZ5/Lange et al. - 2025.pdf")

    # ------------------------------------------------------- notes and cite

    def test_notes_strip_html(self):
        self.server.route(LIB + "/items/K8ZP2VAD/children", [NOTE])
        r = self.run_cli("notes", "K8ZP2VAD")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.query_for(LIB + "/items/K8ZP2VAD/children")["itemType"], ["note"])
        self.assertIn("My summary", r.stdout)
        self.assertIn("Uses islands & novelty.", r.stdout)
        self.assertNotIn("<", r.stdout)

    def test_cite_strips_html(self):
        bib = '<div class="csl-bib-body"><div class="csl-entry">Lange, R. T. (2025). <i>ShinkaEvolve</i>.</div><span class="Z3988" title="x"></span></div>'
        self.server.route(LIB + "/items/top", [{"key": "K8ZP2VAD", "citation": "(Lange, 2025)", "bib": bib}])
        r = self.run_cli("cite", "K8ZP2VAD", "--style", "ieee")
        self.assertEqual(r.returncode, 0, r.stderr)
        q = self.query_for(LIB + "/items/top")
        self.assertEqual(q["itemKey"], ["K8ZP2VAD"])
        self.assertEqual(q["include"], ["citation,bib"])
        self.assertEqual(q["style"], ["ieee"])
        self.assertIn("Lange, R. T. (2025). ShinkaEvolve.", r.stdout)
        self.assertIn("(Lange, 2025)", r.stdout)
        self.assertNotIn("<", r.stdout)

    # ---------------------------------------------------------------- export

    def test_export_passes_keys_and_format(self):
        self.server.route(LIB + "/items/top", "@misc{a,\n}\n@misc{b,\n}\n", content_type="text/plain")
        r = self.run_cli("export", "K8ZP2VAD", "GV2PI5CY", "--format", "bibtex")
        self.assertEqual(r.returncode, 0, r.stderr)
        q = self.query_for(LIB + "/items/top")
        self.assertEqual(q["itemKey"], ["K8ZP2VAD,GV2PI5CY"])
        self.assertEqual(q["format"], ["bibtex"])
        self.assertIn("@misc{a,", r.stdout)

    # ------------------------------------------------- collections and tags

    def test_collections_tree(self):
        cols = [
            {"key": "AAAAAAAA", "meta": {"numItems": 3}, "data": {"key": "AAAAAAAA", "name": "Parent", "parentCollection": False}},
            {"key": "BBBBBBBB", "meta": {"numItems": 1}, "data": {"key": "BBBBBBBB", "name": "Child", "parentCollection": "AAAAAAAA"}},
        ]
        self.server.route(LIB + "/collections", cols, headers={"Total-Results": "2"})
        r = self.run_cli("collections", "--tree")
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = r.stdout.splitlines()
        self.assertTrue(lines[0].startswith("AAAAAAAA"), lines)
        self.assertIn("Parent", lines[0])
        self.assertIn("(3)", lines[0])
        self.assertTrue(lines[1].startswith("  BBBBBBBB"), lines)

    def test_tags_filter(self):
        self.server.route(LIB + "/items/tags", [{"tag": "Machine Learning", "meta": {"numItems": 4}}], headers={"Total-Results": "1"})
        r = self.run_cli("tags", "learn")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.query_for(LIB + "/items/tags")["q"], ["learn"])
        self.assertIn("Machine Learning", r.stdout)

    # -------------------------------------------------------- library, json, raw

    def test_group_library(self):
        entry = item("PBMTTM93", "Hebbian", creator_summary="\u2068Halvagal\u2069 and \u2068Zenke\u2069")
        self.server.route("/api/groups/123/items/top", [entry], headers={"Total-Results": "1"})
        r = self.run_cli("--library", "group:123", "search")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.paths(), ["/api/groups/123/items/top"])
        self.assertIn("\tHalvagal and Zenke\t", r.stdout)

    def test_json_output(self):
        self.server.route(LIB + "/items/top", [PARENT], headers={"Total-Results": "1"})
        r = self.run_cli("--json", "search", "x")
        self.assertEqual(r.returncode, 0, r.stderr)
        out = json.loads(r.stdout)
        self.assertEqual(out["total"], 1)
        self.assertEqual(out["items"][0]["key"], "K8ZP2VAD")
        self.assertEqual(out["items"][0]["title"], PARENT["data"]["title"])

    def test_raw_passes_params(self):
        self.server.route(LIB + "/searches", [], headers={"Total-Results": "0"})
        r = self.run_cli("raw", "/users/0/searches", "limit=3")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.query_for(LIB + "/searches")["limit"], ["3"])
        self.assertEqual(r.stdout.strip(), "[]")

    # ---------------------------------------------------------------- writes

    def auth_file(self):
        return os.path.join(self.config.name, "zotero-local", "auth.json")

    def setup_write(self, key="K" * 32):
        """Serve a server ID on /api/ and store a write key for it."""
        self.server.route("/api/", "Nothing to see here.", headers={"Zotero-Server-ID": "SRV1"}, content_type="text/plain")
        if key:
            os.makedirs(os.path.dirname(self.auth_file()), exist_ok=True)
            with open(self.auth_file(), "w") as f:
                json.dump({"SRV1": {"key": key, "remember": True}}, f)

    def writes(self):
        return [r for r in self.server.log if r["method"] != "GET"]

    def report(self, key="NEWNOTE1"):
        return {"successful": {"0": {"key": key}}, "success": {"0": key}, "unchanged": {}, "failed": {}}

    def test_authorize_stores_key_per_server(self):
        self.setup_write(key=None)
        self.server.route("/api/local/authorize", {"key": "A" * 32, "remember": True}, method="POST")
        r = self.run_cli("authorize", "--app-name", "Test App")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Always Allow", r.stderr)
        (req,) = self.writes()
        self.assertEqual(req["path"], "/api/local/authorize")
        self.assertEqual(req["headers"]["zotero-server-id"], "SRV1")
        self.assertEqual(req["body"], {"appName": "Test App"})
        with open(self.auth_file()) as f:
            self.assertEqual(json.load(f)["SRV1"]["key"], "A" * 32)
        self.assertEqual(stat.S_IMODE(os.stat(self.auth_file()).st_mode), 0o600)

    def test_authorize_single_use_warns(self):
        self.setup_write(key=None)
        self.server.route("/api/local/authorize", {"key": "A" * 32, "remember": False}, method="POST")
        r = self.run_cli("authorize")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("single-use", r.stderr)

    def test_authorize_denied(self):
        self.setup_write(key=None)
        self.server.route("/api/local/authorize", {"denied": True}, status=403, method="POST")
        r = self.run_cli("authorize")
        self.assertEqual(r.returncode, 3)
        self.assertIn("denied", r.stderr)
        self.assertFalse(os.path.exists(self.auth_file()))

    def test_write_needs_server_id(self):
        self.server.route("/api/", "Nothing to see here.", content_type="text/plain")
        r = self.run_cli("add-note", "K8ZP2VAD", "--text", "x")
        self.assertEqual(r.returncode, 1)
        self.assertIn("Zotero 10", r.stderr)
        self.assertEqual(self.writes(), [])

    def test_write_without_key(self):
        self.setup_write(key=None)
        r = self.run_cli("add-note", "K8ZP2VAD", "--text", "x")
        self.assertEqual(r.returncode, 3)
        self.assertIn("authorize", r.stderr)
        self.assertEqual(self.writes(), [])

    def test_write_rejected_key(self):
        self.setup_write()
        self.server.route(LIB + "/items", "Invalid or expired API key", status=401, content_type="text/plain", method="POST")
        r = self.run_cli("add-note", "K8ZP2VAD", "--text", "x")
        self.assertEqual(r.returncode, 3)
        self.assertIn("authorize", r.stderr)

    def test_env_key_overrides_stored_key(self):
        self.setup_write()
        self.server.route(LIB + "/items", self.report(), method="POST")
        r = self.run_cli("add-note", "K8ZP2VAD", "--text", "x", env_extra={"ZOTERO_LOCAL_API_KEY": "E" * 32})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.writes()[0]["headers"]["zotero-api-key"], "E" * 32)

    def test_add_note_to_parent(self):
        self.setup_write()
        self.server.route(LIB + "/items", self.report(), method="POST")
        r = self.run_cli("add-note", "K8ZP2VAD", "--text", "a & b\nline2\n\nc", "--tag", "t1")
        self.assertEqual(r.returncode, 0, r.stderr)
        (req,) = self.writes()
        self.assertEqual(req["path"], LIB + "/items")
        self.assertEqual(req["headers"]["zotero-server-id"], "SRV1")
        self.assertEqual(req["headers"]["zotero-api-key"], "K" * 32)
        self.assertEqual(req["headers"]["zotero-allowed-request"], "1")
        self.assertEqual(
            req["body"],
            [{"itemType": "note", "note": "<p>a &amp; b<br>line2</p>\n<p>c</p>", "parentItem": "K8ZP2VAD", "tags": [{"tag": "t1"}]}],
        )
        self.assertEqual(r.stdout.strip(), "created\tNEWNOTE1")

    def test_add_standalone_note_html_in_collection(self):
        self.setup_write()
        self.server.route(LIB + "/items", self.report(), method="POST")
        r = self.run_cli("add-note", "--html", "<h1>T</h1>", "--collection", "R5MINMKC")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.writes()[0]["body"], [{"itemType": "note", "note": "<h1>T</h1>", "collections": ["R5MINMKC"]}])

    def test_add_note_from_file(self):
        self.setup_write()
        self.server.route(LIB + "/items", self.report(), method="POST")
        path = os.path.join(self.config.name, "n.md")
        with open(path, "w") as f:
            f.write("<x>")
        r = self.run_cli("add-note", "K8ZP2VAD", "--file", path)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.writes()[0]["body"][0]["note"], "<p>&lt;x&gt;</p>")

    def test_add_child_note_rejects_collection(self):
        self.setup_write()
        r = self.run_cli("add-note", "K8ZP2VAD", "--text", "x", "--collection", "R5MINMKC")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.server.log, [])

    def test_write_report_failure(self):
        self.setup_write()
        failed = {"successful": {}, "success": {}, "unchanged": {}, "failed": {"0": {"key": "", "code": 400, "message": "Parent item X not found"}}}
        self.server.route(LIB + "/items", failed, method="POST")
        r = self.run_cli("add-note", "K8ZP2VAD", "--text", "x")
        self.assertEqual(r.returncode, 1)
        self.assertIn("Parent item X not found", r.stderr)

    def note_entry(self, version=7):
        entry = json.loads(json.dumps(NOTE))
        entry["data"]["version"] = version
        return entry

    def test_edit_note_append(self):
        self.setup_write()
        self.server.route(LIB + "/items/62UPL4XJ", self.note_entry())
        self.server.route(LIB + "/items/62UPL4XJ", "", status=204, method="PATCH")
        r = self.run_cli("edit-note", "62UPL4XJ", "--append", "--text", "more")
        self.assertEqual(r.returncode, 0, r.stderr)
        (req,) = self.writes()
        self.assertEqual(req["body"], {"note": NOTE["data"]["note"] + "<p>more</p>", "version": 7})
        self.assertEqual(r.stdout.strip(), "updated\t62UPL4XJ")

    def test_edit_note_replace_rejects_non_note(self):
        self.setup_write()
        self.server.route(LIB + "/items/K8ZP2VAD", PARENT)
        r = self.run_cli("edit-note", "K8ZP2VAD", "--html", "<p>x</p>")
        self.assertEqual(r.returncode, 1)
        self.assertIn("not a note", r.stderr)
        self.assertEqual(self.writes(), [])

    def parent_entry(self, version=5):
        entry = json.loads(json.dumps(PARENT))
        entry["data"]["version"] = version
        entry["data"]["tags"] = [{"tag": "keep", "type": 1}, {"tag": "old"}]
        return entry

    def test_tag_add_remove(self):
        self.setup_write()
        self.server.route(LIB + "/items/K8ZP2VAD", self.parent_entry())
        self.server.route(LIB + "/items/K8ZP2VAD", "", status=204, method="PATCH")
        r = self.run_cli("tag", "K8ZP2VAD", "--add", "new", "--remove", "old")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.writes()[0]["body"], {"tags": [{"tag": "keep", "type": 1}, {"tag": "new"}], "version": 5})

    def test_tag_unchanged_skips_patch(self):
        self.setup_write()
        self.server.route(LIB + "/items/K8ZP2VAD", self.parent_entry())
        r = self.run_cli("tag", "K8ZP2VAD", "--add", "keep", "--remove", "absent")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.writes(), [])
        self.assertEqual(r.stdout.strip(), "unchanged\tK8ZP2VAD")

    def route_collection(self, key="AAAAAAAA"):
        self.server.route(LIB + "/collections/" + key, {"key": key, "data": {"key": key, "name": "C"}})

    def test_collect_add_and_remove(self):
        self.setup_write()
        self.route_collection()
        self.server.route(LIB + "/items/K8ZP2VAD", self.parent_entry())
        self.server.route(LIB + "/items/K8ZP2VAD", "", status=204, method="PATCH")
        r = self.run_cli("collect", "K8ZP2VAD", "--add", "AAAAAAAA")
        self.assertEqual(r.returncode, 0, r.stderr)
        r = self.run_cli("collect", "K8ZP2VAD", "--remove", "R5MINMKC")
        self.assertEqual(r.returncode, 0, r.stderr)
        bodies = [w["body"] for w in self.writes()]
        self.assertEqual(bodies, [{"collections": ["R5MINMKC", "AAAAAAAA"], "version": 5}, {"collections": [], "version": 5}])

    def test_collect_rejects_child_item(self):
        self.setup_write()
        self.route_collection()
        self.server.route(LIB + "/items/62UPL4XJ", self.note_entry())
        r = self.run_cli("collect", "62UPL4XJ", "--add", "AAAAAAAA")
        self.assertEqual(r.returncode, 1)
        self.assertIn("child", r.stderr)
        self.assertEqual(self.writes(), [])

    def test_create_collection(self):
        self.setup_write()
        self.server.route(LIB + "/collections", self.report("NEWCOLL1"), method="POST")
        r = self.run_cli("create-collection", "Reading list", "--parent", "AAAAAAAA")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.writes()[0]["body"], [{"name": "Reading list", "parentCollection": "AAAAAAAA"}])
        self.assertEqual(r.stdout.strip(), "created\tNEWCOLL1")

    def test_update_fields(self):
        self.setup_write()
        self.server.route(LIB + "/items/K8ZP2VAD", self.parent_entry())
        self.server.route("/api/itemTypeFields", [{"field": "title"}, {"field": "extra"}, {"field": "date"}])
        self.server.route(LIB + "/items/K8ZP2VAD", "", status=204, method="PATCH")
        r = self.run_cli("update", "K8ZP2VAD", "bogus=1")
        self.assertEqual(r.returncode, 1)
        self.assertIn("bogus", r.stderr)
        self.assertEqual(self.writes(), [])
        r = self.run_cli("update", "K8ZP2VAD", "extra=Read: yes", "date=")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.query_for("/api/itemTypeFields")["itemType"], ["preprint"])
        self.assertEqual(self.writes()[0]["body"], {"extra": "Read: yes", "date": "", "version": 5})

    def test_trash_and_restore(self):
        self.setup_write()
        self.server.route(LIB + "/items/K8ZP2VAD", self.parent_entry())
        self.server.route(LIB + "/items/K8ZP2VAD", "", status=204, method="PATCH")
        r = self.run_cli("trash", "K8ZP2VAD")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "trashed\tK8ZP2VAD")
        trashed = self.parent_entry()
        trashed["data"]["deleted"] = True
        self.server.route(LIB + "/items/K8ZP2VAD", trashed)
        r = self.run_cli("restore", "K8ZP2VAD")
        self.assertEqual(r.returncode, 0, r.stderr)
        bodies = [w["body"] for w in self.writes()]
        self.assertEqual(bodies, [{"deleted": True, "version": 5}, {"deleted": False, "version": 5}])
        self.assertTrue(all(w["method"] == "PATCH" for w in self.writes()))

    def test_restore_untrashed_is_noop(self):
        self.setup_write()
        self.server.route(LIB + "/items/K8ZP2VAD", self.parent_entry())
        r = self.run_cli("restore", "K8ZP2VAD")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.writes(), [])
        self.assertEqual(r.stdout.strip(), "unchanged\tK8ZP2VAD")

    def test_dry_run_sends_no_write(self):
        self.setup_write()
        self.server.route(LIB + "/items/K8ZP2VAD", self.parent_entry())
        r = self.run_cli("--dry-run", "trash", "K8ZP2VAD")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.writes(), [])
        self.assertIn("DRY RUN: PATCH " + LIB + "/items/K8ZP2VAD", r.stdout)
        self.assertIn('"deleted": true', r.stdout)

    def test_version_conflict(self):
        self.setup_write()
        self.server.route(LIB + "/items/K8ZP2VAD", self.parent_entry())
        self.server.route(LIB + "/items/K8ZP2VAD", "item version mismatch", status=412, content_type="text/plain", method="PATCH")
        r = self.run_cli("trash", "K8ZP2VAD")
        self.assertEqual(r.returncode, 1)
        self.assertIn("changed in Zotero", r.stderr)

    def test_ping_reports_write_status(self):
        self.setup_write(key=None)
        self.server.route(LIB + "/items/top", [], headers={"Total-Results": "1"})
        r = self.run_cli("ping")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("not authorized", r.stdout)
        self.setup_write()
        r = self.run_cli("ping")
        self.assertIn("key stored", r.stdout)


if __name__ == "__main__":
    unittest.main()
