#!/usr/bin/env python3
import json
import os
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM_BASE_URL = os.environ.get("UPSTREAM_BASE_URL", "http://kms-shim.vault-seal-system.svc:8200").strip().rstrip("/")
if not UPSTREAM_BASE_URL:
    raise RuntimeError("UPSTREAM_BASE_URL is required")

STATE_FILE = os.environ.get("STATE_FILE", "/tmp/kms-shim-external-proxy-state.json").strip() or "/tmp/kms-shim-external-proxy-state.json"
_LOCK = threading.Lock()


HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "host",
    "content-length",
}


def _load_state() -> dict:
    if not os.path.exists(STATE_FILE):
        return {"requestCount": 0, "requests": []}
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as f:
            value = json.load(f)
            if not isinstance(value, dict):
                return {"requestCount": 0, "requests": []}
            if "requests" not in value or not isinstance(value["requests"], list):
                value["requests"] = []
            value["requestCount"] = len(value["requests"])
            return value
    except Exception:
        return {"requestCount": 0, "requests": []}


def _save_state(state: dict) -> None:
    tmp = f"{STATE_FILE}.tmp"
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(state, f, separators=(",", ":"), sort_keys=True)
    os.replace(tmp, STATE_FILE)


def _append_request(record: dict) -> None:
    with _LOCK:
        state = _load_state()
        requests = state.get("requests", [])
        requests.append(record)
        if len(requests) > 300:
            requests = requests[-300:]
        state["requests"] = requests
        state["requestCount"] = len(requests)
        _save_state(state)


def _reset_state() -> None:
    with _LOCK:
        _save_state({"requestCount": 0, "requests": []})


def _send_json(handler: BaseHTTPRequestHandler, status: int, payload: dict) -> None:
    data = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args) -> None:
        return

    def _handle_state_paths(self) -> bool:
        if self.path == "/__health":
            _send_json(self, 200, {"ok": True, "ts": int(time.time()), "upstream": UPSTREAM_BASE_URL})
            return True
        if self.path == "/__state":
            with _LOCK:
                _send_json(self, 200, _load_state())
            return True
        if self.path == "/__reset":
            _reset_state()
            _send_json(self, 200, {"ok": True})
            return True
        return False

    def _proxy(self, method: str) -> None:
        if self._handle_state_paths():
            return

        raw_len = self.headers.get("Content-Length", "0")
        try:
            body_len = int(raw_len)
        except ValueError:
            body_len = 0
        body = self.rfile.read(body_len) if body_len > 0 else b""

        target = f"{UPSTREAM_BASE_URL}{self.path}"
        req = urllib.request.Request(target, data=body if method in ("POST", "PUT") else None, method=method)
        for k, v in self.headers.items():
            if k.lower() in HOP_HEADERS:
                continue
            req.add_header(k, v)

        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                resp_body = resp.read()
                status = resp.getcode()
                self.send_response(status)
                for hk, hv in resp.headers.items():
                    if hk.lower() in HOP_HEADERS:
                        continue
                    self.send_header(hk, hv)
                self.send_header("Content-Length", str(len(resp_body)))
                self.end_headers()
                self.wfile.write(resp_body)
                _append_request(
                    {
                        "ts": int(time.time()),
                        "method": method,
                        "path": self.path,
                        "status": status,
                    }
                )
        except urllib.error.HTTPError as exc:
            body_bytes = exc.read()
            status = exc.code
            self.send_response(status)
            self.send_header("Content-Length", str(len(body_bytes)))
            self.end_headers()
            if body_bytes:
                self.wfile.write(body_bytes)
            _append_request(
                {
                    "ts": int(time.time()),
                    "method": method,
                    "path": self.path,
                    "status": status,
                }
            )
        except Exception as exc:
            _append_request(
                {
                    "ts": int(time.time()),
                    "method": method,
                    "path": self.path,
                    "status": 502,
                    "error": str(exc),
                }
            )
            _send_json(self, 502, {"errors": [str(exc)]})

    def do_GET(self) -> None:  # noqa: N802
        self._proxy("GET")

    def do_POST(self) -> None:  # noqa: N802
        self._proxy("POST")

    def do_PUT(self) -> None:  # noqa: N802
        self._proxy("PUT")


def main() -> None:
    port = int(os.environ.get("PORT", "8200"))
    if not os.path.exists(STATE_FILE):
        _reset_state()
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
