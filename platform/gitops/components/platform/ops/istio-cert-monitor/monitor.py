#!/usr/bin/env python3

import datetime as _dt
import json
import os
import re
import subprocess
import sys
from typing import Any, Dict, Iterable, List, Optional, Tuple


RESTART_ANNOTATION = "darksite.cloud/istio-cert-monitor-last-restart"
SECONDS_LEFT_ANNOTATION = "darksite.cloud/istio-cert-monitor-last-seconds-remaining"


def _utc_now() -> _dt.datetime:
    return _dt.datetime.now(tz=_dt.timezone.utc)


def _log(msg: str) -> None:
    ts = _utc_now().isoformat().replace("+00:00", "Z")
    print(f"[{ts}] {msg}", flush=True)


def _run(argv: List[str], *, check: bool = True, text: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(argv, check=check, text=text, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def _require_cmd(cmd: str) -> None:
    try:
        _run([cmd, "--help"], check=False)
    except FileNotFoundError:
        raise RuntimeError(f"missing dependency: {cmd}")


def _load_targets(path: str) -> List[Dict[str, Any]]:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, list):
        raise ValueError("targets.json must be a JSON array")
    for idx, entry in enumerate(data):
        if not isinstance(entry, dict):
            raise ValueError(f"targets.json entry #{idx} must be an object")
        for k in ("namespace", "kind", "name"):
            if not entry.get(k):
                raise ValueError(f"targets.json entry #{idx} missing required field: {k}")
    return data


def _labels_to_selector(labels: Dict[str, str]) -> str:
    parts = []
    for k, v in labels.items():
        parts.append(f"{k}={v}")
    return ",".join(parts)


def _pick_running_pod(pods_json: Dict[str, Any], *, required_container: str) -> Optional[str]:
    items = pods_json.get("items", [])
    candidates: List[Tuple[_dt.datetime, str]] = []
    for item in items:
        if item.get("status", {}).get("phase") != "Running":
            continue
        containers = item.get("spec", {}).get("containers", [])
        container_names = {c.get("name") for c in containers}
        if required_container not in container_names:
            continue
        start_time_str = item.get("status", {}).get("startTime", "")
        start_time = _parse_rfc3339(start_time_str) or _utc_now()
        candidates.append((start_time, item.get("metadata", {}).get("name", "")))
    if not candidates:
        return None
    candidates.sort(reverse=True)
    return candidates[0][1] or None


def _parse_rfc3339(s: str) -> Optional[_dt.datetime]:
    if not s:
        return None
    try:
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        dt = _dt.datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=_dt.timezone.utc)
        return dt.astimezone(_dt.timezone.utc)
    except Exception:
        return None


def _find_pems(value: Any) -> Iterable[str]:
    if isinstance(value, str) and "BEGIN CERTIFICATE" in value:
        yield value
        return
    if isinstance(value, dict):
        for v in value.values():
            yield from _find_pems(v)
    if isinstance(value, list):
        for v in value:
            yield from _find_pems(v)


_EXPIRY_KEYS = {
    "validTo",
    "notAfter",
    "expirationTime",
    "expiration_time",
}


def _find_expiry_strings(value: Any) -> Iterable[str]:
    if isinstance(value, dict):
        for k, v in value.items():
            if k in _EXPIRY_KEYS and isinstance(v, str):
                yield v
            yield from _find_expiry_strings(v)
    elif isinstance(value, list):
        for v in value:
            yield from _find_expiry_strings(v)


_PEM_FIRST_CERT_RE = re.compile(
    r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
    re.DOTALL,
)


def _openssl_not_after(pem: str) -> _dt.datetime:
    m = _PEM_FIRST_CERT_RE.search(pem)
    if not m:
        raise ValueError("no PEM certificate found")
    first_cert = m.group(0)
    proc = subprocess.run(
        ["openssl", "x509", "-noout", "-enddate"],
        input=first_cert,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    out = proc.stdout.strip()
    if not out.startswith("notAfter="):
        raise ValueError(f"unexpected openssl output: {out}")
    not_after = out[len("notAfter=") :]
    # Example: "Dec 15 12:34:56 2025 GMT"
    if not_after.endswith(" GMT"):
        not_after = not_after[: -len(" GMT")]
    dt = _dt.datetime.strptime(not_after, "%b %d %H:%M:%S %Y").replace(tzinfo=_dt.timezone.utc)
    return dt


def _extract_earliest_expiry_seconds(certs_json_text: str) -> Optional[int]:
    try:
        data = json.loads(certs_json_text)
    except Exception:
        return None

    certificates: List[Any]
    if isinstance(data, dict) and isinstance(data.get("certificates"), list):
        certificates = data["certificates"]
    elif isinstance(data, list):
        certificates = data
    else:
        certificates = []

    expiries: List[_dt.datetime] = []
    for cert in certificates:
        for pem in _find_pems(cert):
            try:
                expiries.append(_openssl_not_after(pem))
            except Exception:
                continue
        for exp in _find_expiry_strings(cert):
            dt = _parse_rfc3339(exp)
            if dt:
                expiries.append(dt)

    if not expiries:
        return None
    earliest = min(expiries)
    remaining = int((earliest - _utc_now()).total_seconds())
    return remaining


def _get_workload(ns: str, kind: str, name: str) -> Dict[str, Any]:
    proc = _run(["kubectl", "-n", ns, "get", f"{kind}/{name}", "-o", "json"])
    return json.loads(proc.stdout)


def _maybe_int(v: Optional[str]) -> Optional[int]:
    if v is None:
        return None
    try:
        return int(v)
    except Exception:
        return None


def _restart_workload(ns: str, kind: str, name: str, remaining: int, *, dry_run: bool) -> None:
    ts = str(int(_utc_now().timestamp()))
    if dry_run:
        _log(f"DRY_RUN=true: would rollout-restart {ns} {kind}/{name} (remaining={remaining}s)")
        return
    _log(f"rollout-restart {ns} {kind}/{name} (remaining={remaining}s)")
    proc = _run(["kubectl", "-n", ns, "rollout", "restart", f"{kind}/{name}"], check=False)
    if proc.returncode != 0:
        _log(f"ERROR: rollout restart failed for {ns} {kind}/{name}: {proc.stderr.strip()}")
        return
    _run(
        [
            "kubectl",
            "-n",
            ns,
            "annotate",
            f"{kind}/{name}",
            f"{RESTART_ANNOTATION}={ts}",
            f"{SECONDS_LEFT_ANNOTATION}={remaining}",
            "--overwrite",
        ],
        check=False,
    )


def main() -> int:
    _require_cmd("kubectl")
    _require_cmd("openssl")

    targets_path = os.environ.get("TARGETS_PATH", "/config/targets.json")
    threshold_seconds = int(os.environ.get("THRESHOLD_SECONDS", "7200"))
    cooldown_seconds = int(os.environ.get("COOLDOWN_SECONDS", "3600"))
    dry_run = os.environ.get("DRY_RUN", "false").lower() == "true"
    require_at_least_one_success = os.environ.get("REQUIRE_AT_LEAST_ONE_SUCCESS", "false").lower() == "true"
    fail_on_error = os.environ.get("FAIL_ON_ERROR", "false").lower() == "true"

    targets = _load_targets(targets_path)
    _log(
        "starting ("
        f"targets={len(targets)} "
        f"threshold={threshold_seconds}s "
        f"cooldown={cooldown_seconds}s "
        f"dry_run={dry_run} "
        f"require_success={require_at_least_one_success} "
        f"fail_on_error={fail_on_error}"
        ")"
    )

    successes = 0
    errors = 0

    for t in targets:
        ns = str(t["namespace"])
        kind = str(t["kind"])
        name = str(t["name"])
        proxy_container = str(t.get("proxyContainer") or "istio-proxy")

        try:
            workload = _get_workload(ns, kind, name)
        except subprocess.CalledProcessError as e:
            _log(f"ERROR: failed to get workload {ns} {kind}/{name}: {e.stderr.strip()}")
            errors += 1
            continue

        ann = (workload.get("metadata", {}) or {}).get("annotations", {}) or {}
        last_restart = _maybe_int(ann.get(RESTART_ANNOTATION))
        if last_restart is not None:
            age = int(_utc_now().timestamp()) - last_restart
            if age < cooldown_seconds:
                _log(f"skip {ns} {kind}/{name}: cooldown active ({age}s < {cooldown_seconds}s)")
                continue

        labels = ((workload.get("spec", {}) or {}).get("selector", {}) or {}).get("matchLabels", {}) or {}
        if not isinstance(labels, dict) or not labels:
            _log(f"ERROR: {ns} {kind}/{name}: missing spec.selector.matchLabels; cannot find pods")
            errors += 1
            continue
        selector = _labels_to_selector({str(k): str(v) for k, v in labels.items()})

        try:
            pods_proc = _run(["kubectl", "-n", ns, "get", "pods", "-l", selector, "-o", "json"])
            pods_json = json.loads(pods_proc.stdout)
        except subprocess.CalledProcessError as e:
            _log(f"ERROR: failed to list pods for {ns} {kind}/{name}: {e.stderr.strip()}")
            errors += 1
            continue

        pod = _pick_running_pod(pods_json, required_container=proxy_container)
        if not pod:
            _log(f"skip {ns} {kind}/{name}: no Running pod with container '{proxy_container}'")
            continue

        certs_proc = _run(
            [
                "kubectl",
                "-n",
                ns,
                "exec",
                pod,
                "-c",
                proxy_container,
                "--",
                "pilot-agent",
                "request",
                "GET",
                "certs",
            ],
            check=False,
        )
        if certs_proc.returncode != 0:
            _log(
                f"ERROR: failed to query certs for {ns} {kind}/{name} (pod={pod}): {certs_proc.stderr.strip()}"
            )
            errors += 1
            continue

        remaining = _extract_earliest_expiry_seconds(certs_proc.stdout)
        if remaining is None:
            _log(f"ERROR: could not parse cert expiry for {ns} {kind}/{name} (pod={pod})")
            errors += 1
            continue

        _log(f"{ns} {kind}/{name}: earliest cert remaining={remaining}s (pod={pod})")
        successes += 1
        if remaining <= threshold_seconds:
            _restart_workload(ns, kind, name, remaining, dry_run=dry_run)

    _log("done")

    if require_at_least_one_success and successes < 1:
        _log("ERROR: REQUIRE_AT_LEAST_ONE_SUCCESS=true but no successful target checks occurred")
        return 1

    if fail_on_error and errors > 0:
        _log(f"ERROR: FAIL_ON_ERROR=true and errors={errors} (>0)")
        return 1

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        _log(f"FATAL: {e}")
        sys.exit(2)
