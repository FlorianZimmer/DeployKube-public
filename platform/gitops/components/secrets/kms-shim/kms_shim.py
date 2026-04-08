import base64
import json
import os
import subprocess
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "0.1.0"


def _require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"missing required env var: {name}")
    return value


KMS_SHIM_TOKEN = _require_env("KMS_SHIM_TOKEN")
AGE_KEY_FILE = os.environ.get("KMS_SHIM_AGE_KEY_FILE", "/etc/kms/age.key").strip()
if not AGE_KEY_FILE:
    raise RuntimeError("KMS_SHIM_AGE_KEY_FILE is empty")
if not os.path.exists(AGE_KEY_FILE):
    raise RuntimeError(f"age key file does not exist: {AGE_KEY_FILE}")


def _run_age(args: list[str], stdin_bytes: bytes) -> bytes:
    proc = subprocess.run(
        args,
        input=stdin_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode != 0:
        stderr = proc.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"age failed (rc={proc.returncode}): {stderr}")
    return proc.stdout


def _age_encrypt(plaintext: bytes) -> bytes:
    return _run_age(["age", "-e", "-i", AGE_KEY_FILE, "-o", "-", "-"], plaintext)


def _age_decrypt(ciphertext: bytes) -> bytes:
    return _run_age(["age", "-d", "-i", AGE_KEY_FILE, "-o", "-", "-"], ciphertext)


def _read_json_body(handler: BaseHTTPRequestHandler) -> dict:
    length_raw = handler.headers.get("Content-Length", "0")
    try:
        length = int(length_raw)
    except ValueError:
        length = 0
    body = handler.rfile.read(length) if length > 0 else b""
    try:
        return json.loads(body.decode("utf-8")) if body else {}
    except json.JSONDecodeError:
        raise ValueError("invalid JSON body")


def _send_json(handler: BaseHTTPRequestHandler, status: int, payload: dict) -> None:
    data = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(data)))
    handler.end_headers()
    handler.wfile.write(data)


def _require_token(handler: BaseHTTPRequestHandler) -> None:
    token = handler.headers.get("X-Vault-Token", "").strip()
    if not token:
        raise PermissionError("missing X-Vault-Token")
    if token != KMS_SHIM_TOKEN:
        raise PermissionError("invalid token")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args) -> None:
        # Keep logs minimal; this service sits on a critical bootstrap path.
        return

    def do_GET(self) -> None:  # noqa: N802
        if self.path in ("/v1/sys/health", "/v1/sys/seal-status"):
            _send_json(
                self,
                200,
                {
                    "initialized": True,
                    "sealed": False,
                    "standby": False,
                    "server_time_utc": int(time.time()),
                    "version": f"kms-shim/{VERSION}",
                },
            )
            return

        _send_json(self, 404, {"errors": ["not found"]})

    def do_POST(self) -> None:  # noqa: N802
        if self.path.startswith("/v1/transit/encrypt/"):
            try:
                _require_token(self)
                body = _read_json_body(self)
                plaintext_b64 = (body.get("plaintext") or "").strip()
                if not plaintext_b64:
                    _send_json(self, 400, {"errors": ["missing plaintext"]})
                    return

                plaintext = base64.b64decode(plaintext_b64)
                ciphertext_bytes = _age_encrypt(plaintext)
                ciphertext_b64 = base64.b64encode(ciphertext_bytes).decode("ascii")
                _send_json(self, 200, {"data": {"ciphertext": f"vault:v1:{ciphertext_b64}"}})
                return
            except PermissionError as e:
                _send_json(self, 403, {"errors": [str(e)]})
                return
            except ValueError as e:
                _send_json(self, 400, {"errors": [str(e)]})
                return
            except Exception as e:
                _send_json(self, 500, {"errors": [str(e)]})
                return

        if self.path.startswith("/v1/transit/decrypt/"):
            try:
                _require_token(self)
                body = _read_json_body(self)
                ciphertext = (body.get("ciphertext") or "").strip()
                if not ciphertext:
                    _send_json(self, 400, {"errors": ["missing ciphertext"]})
                    return
                if ciphertext.startswith("vault:v1:"):
                    ciphertext = ciphertext[len("vault:v1:") :]

                ciphertext_bytes = base64.b64decode(ciphertext)
                plaintext = _age_decrypt(ciphertext_bytes)
                plaintext_b64 = base64.b64encode(plaintext).decode("ascii")
                _send_json(self, 200, {"data": {"plaintext": plaintext_b64}})
                return
            except PermissionError as e:
                _send_json(self, 403, {"errors": [str(e)]})
                return
            except ValueError as e:
                _send_json(self, 400, {"errors": [str(e)]})
                return
            except Exception as e:
                _send_json(self, 500, {"errors": [str(e)]})
                return

        _send_json(self, 404, {"errors": ["not found"]})

    def do_PUT(self) -> None:  # noqa: N802
        # OpenBao's transit seal implementation uses PUT requests for encrypt/decrypt.
        # Treat PUT as POST for the supported endpoints.
        self.do_POST()


def main() -> None:
    port = int(os.environ.get("PORT", "8200"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()

