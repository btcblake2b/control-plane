#!/usr/bin/env python3
"""Mock minimale del control plane per i test dell'installer.

MAI usato in produzione: risponde a POST /v1/register con esiti simulati.
Uso: mock_cp.py --port 8099 --mode ok|expired
"""
import argparse
import json
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    mode = "ok"

    def do_POST(self):  # noqa: N802 (API stdlib)
        length = int(self.headers.get("Content-Length", "0"))
        _ = self.rfile.read(length)
        if self.path != "/v1/register":
            self.send_response(404)
            self.end_headers()
            return
        if Handler.mode == "expired":
            self.send_response(410)
            payload = {
                "error": {"code": "TOKEN_EXPIRED", "message": "token scaduto"}
            }
        else:
            self.send_response(201)
            payload = {
                "nodeId": "a" * 32,
                "nodeSecret": "b" * 64,
                "createdAt": "2026-09-14T00:00:00Z",
            }
        data = json.dumps(payload).encode()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass  # silenzio: output dei test solo dagli assert


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8099)
    parser.add_argument("--mode", choices=["ok", "expired"], default="ok")
    opts = parser.parse_args()
    Handler.mode = opts.mode
    HTTPServer(("127.0.0.1", opts.port), Handler).serve_forever()
