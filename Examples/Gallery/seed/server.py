"""Local-only preview. No external requests, package downloads or private images."""
import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

from catalog import catalogue
from page import render


def response(target):
    url = urlsplit(target)
    if url.path not in {"/", "/api/photos"}:
        return 404, "text/plain", "Page not found"
    query = parse_qs(url.query)
    category = query.get("category", [""])[0]
    try:
        page = int(query.get("page", ["1"])[0])
        if page < 1:
            raise ValueError
    except ValueError:
        return 400, "text/plain", "Page must be a positive integer"
    result = catalogue(category, page)
    if url.path == "/api/photos":
        return 200, "application/json", json.dumps(result)
    return 200, "text/html", render(result, category)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        code, mime, content = response(self.path)
        body = content.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", mime + "; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    with ThreadingHTTPServer(("127.0.0.1", args.port), Handler) as server:
        print(f"Field Notes preview on http://127.0.0.1:{server.server_port}/", flush=True)
        server.serve_forever()
