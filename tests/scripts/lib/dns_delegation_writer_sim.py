#!/usr/bin/env python3
import json
import os
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE_FILE = os.environ.get("STATE_FILE", "/tmp/dns-delegation-writer-state.json").strip() or "/tmp/dns-delegation-writer-state.json"
SIM_API_KEY = os.environ.get("SIM_API_KEY", "").strip()
if not SIM_API_KEY:
    raise RuntimeError("SIM_API_KEY is required")

_LOCK = threading.Lock()


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
        if len(requests) > 200:
            requests = requests[-200:]
        state["requests"] = requests
        state["requestCount"] = len(requests)
        _save_state(state)


def _reset_state() -> None:
    with _LOCK:
        _save_state({"requestCount": 0, "requests": []})


def _read_json_body(handler: BaseHTTPRequestHandler) -> dict:
    raw_len = handler.headers.get("Content-Length", "0")
    try:
        length = int(raw_len)
    except ValueError:
        length = 0
    body = handler.rfile.read(length) if length > 0 else b""
    if not body:
        return {}
    return json.loads(body.decode("utf-8"))


def _send_json(handler: BaseHTTPRequestHandler, status: int, payload: dict) -> None:
    data = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


_PATCH_RE = re.compile(r"^/api/v1/servers/([^/]+)/zones/([^/]+)$")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args) -> None:
        return

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/__health":
            _send_json(self, 200, {"ok": True, "ts": int(time.time())})
            return
        if self.path == "/__state":
            with _LOCK:
                _send_json(self, 200, _load_state())
            return
        if self.path == "/__reset":
            _reset_state()
            _send_json(self, 200, {"ok": True})
            return
        _send_json(self, 404, {"errors": ["not found"]})

    def do_POST(self) -> None:  # noqa: N802
        if self.path == "/__reset":
            _reset_state()
            _send_json(self, 200, {"ok": True})
            return
        _send_json(self, 404, {"errors": ["not found"]})

    def do_PATCH(self) -> None:  # noqa: N802
        m = _PATCH_RE.match(self.path)
        if not m:
            _send_json(self, 404, {"errors": ["not found"]})
            return

        api_key = self.headers.get("X-API-Key", "").strip()
        if api_key != SIM_API_KEY:
            _send_json(self, 403, {"errors": ["invalid api key"]})
            return

        try:
            body = _read_json_body(self)
            rrsets = body.get("rrsets", [])
            if not isinstance(rrsets, list):
                _send_json(self, 400, {"errors": ["rrsets must be a list"]})
                return

            _append_request(
                {
                    "ts": int(time.time()),
                    "path": self.path,
                    "server": m.group(1),
                    "zone": m.group(2),
                    "rrsets": rrsets,
                }
            )
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()
        except json.JSONDecodeError:
            _send_json(self, 400, {"errors": ["invalid json"]})
        except Exception as exc:
            _send_json(self, 500, {"errors": [str(exc)]})


def main() -> None:
    port = int(os.environ.get("PORT", "8081"))
    if not os.path.exists(STATE_FILE):
        _reset_state()
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
