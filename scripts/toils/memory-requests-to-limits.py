#!/usr/bin/env python3

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from typing import Any, Dict, List, Optional, Sequence, Set


def eprint(*args: object) -> None:
    print(*args, file=sys.stderr)


def run_kubectl_json(args: Sequence[str], kubeconfig: Optional[str]) -> Any:
    cmd = ["kubectl"]
    if kubeconfig:
        cmd += ["--kubeconfig", kubeconfig]
    cmd += list(args) + ["-o", "json"]
    out = subprocess.check_output(cmd, text=True)
    return json.loads(out)


def run_kubectl(args: Sequence[str], kubeconfig: Optional[str]) -> str:
    cmd = ["kubectl"]
    if kubeconfig:
        cmd += ["--kubeconfig", kubeconfig]
    cmd += list(args)
    return subprocess.check_output(cmd, text=True)


_BINARY_UNITS = {
    "Ki": 1024**1,
    "Mi": 1024**2,
    "Gi": 1024**3,
    "Ti": 1024**4,
    "Pi": 1024**5,
    "Ei": 1024**6,
}
_DECIMAL_UNITS = {
    "K": 1000**1,
    "M": 1000**2,
    "G": 1000**3,
    "T": 1000**4,
    "P": 1000**5,
    "E": 1000**6,
}
_SMALL_DECIMAL_UNITS = {
    "n": Decimal("0.000000001"),
    "u": Decimal("0.000001"),
    "m": Decimal("0.001"),
}


def parse_bytes(quantity: str) -> Optional[int]:
    q = quantity.strip()
    if q == "":
        return None
    for suf, factor in _BINARY_UNITS.items():
        if q.endswith(suf):
            try:
                return int((Decimal(q[: -len(suf)]) * Decimal(factor)).to_integral_value(rounding="ROUND_FLOOR"))
            except (InvalidOperation, ValueError):
                return None
    for suf, factor in _DECIMAL_UNITS.items():
        if q.endswith(suf):
            try:
                return int((Decimal(q[: -len(suf)]) * Decimal(factor)).to_integral_value(rounding="ROUND_FLOOR"))
            except (InvalidOperation, ValueError):
                return None
    for suf, factor in _SMALL_DECIMAL_UNITS.items():
        if q.endswith(suf):
            try:
                return int((Decimal(q[: -len(suf)]) * factor).to_integral_value(rounding="ROUND_FLOOR"))
            except (InvalidOperation, ValueError):
                return None
    try:
        return int(Decimal(q).to_integral_value(rounding="ROUND_FLOOR"))
    except (InvalidOperation, ValueError):
        return None


def _wants_color(mode: str) -> bool:
    if mode == "never":
        return False
    if mode == "always":
        return True
    # auto
    if os.environ.get("NO_COLOR") is not None:
        return False
    return sys.stderr.isatty()


class _Ansi:
    RED = "\x1b[31m"
    YELLOW = "\x1b[33m"
    CYAN = "\x1b[36m"
    DIM = "\x1b[2m"
    RESET = "\x1b[0m"


@dataclass(frozen=True)
class Issue:
    level: str  # "error" | "warn"
    code: str
    message: str


class IssueCollector:
    def __init__(self, *, color_mode: str, max_details: int, print_immediately: bool) -> None:
        self._issues: List[Issue] = []
        self._use_color = _wants_color(color_mode)
        self._max_details = max_details
        self._print_immediately = print_immediately

    def _emit(self, issue: Issue) -> None:
        self._issues.append(issue)
        if self._print_immediately:
            eprint(self._format_issue(issue))

    def error(self, code: str, message: str) -> None:
        self._emit(Issue(level="error", code=code, message=message))

    def warn(self, code: str, message: str) -> None:
        self._emit(Issue(level="warn", code=code, message=message))

    def _format_issue(self, issue: Issue) -> str:
        tag = "ERROR" if issue.level == "error" else "WARN"
        if not self._use_color:
            return f"{tag} [{issue.code}] {issue.message}"
        color = _Ansi.RED if issue.level == "error" else _Ansi.YELLOW
        return f"{color}{tag}{_Ansi.RESET} {_Ansi.DIM}[{issue.code}]{_Ansi.RESET} {issue.message}"

    def print_summary(self) -> None:
        if not self._issues:
            return

        errors = [i for i in self._issues if i.level == "error"]
        warns = [i for i in self._issues if i.level == "warn"]

        def fmt_heading(text: str) -> str:
            if not self._use_color:
                return text
            return f"{_Ansi.CYAN}{text}{_Ansi.RESET}"

        eprint(fmt_heading("issues summary:"))
        if errors:
            eprint(f"- errors: {len(errors)}")
        if warns:
            eprint(f"- warnings: {len(warns)}")

        limit = self._max_details
        if limit < 0:
            limit = 0
        if limit == 0:
            limit = len(self._issues)

        eprint(fmt_heading("issues details:"))
        shown = 0
        for issue in self._issues:
            if shown >= limit:
                break
            eprint(f"- {self._format_issue(issue)}")
            shown += 1

        remaining = len(self._issues) - shown
        if remaining > 0:
            eprint(
                f"... {remaining} more issues not shown "
                f"(use --issues-max 0 to show all; --print-issues-immediately to stream)."
            )


@dataclass(frozen=True)
class WorkloadRef:
    namespace: str
    kind: str
    name: str


def parse_namespace_list(csv: Optional[str]) -> Optional[Set[str]]:
    if not csv:
        return None
    out = set()
    for part in csv.split(","):
        p = part.strip()
        if p:
            out.add(p)
    return out or None


def match_any(value: str, patterns: Optional[List[re.Pattern[str]]]) -> bool:
    if not patterns:
        return True
    return any(p.search(value) for p in patterns)


def build_regex_list(values: Optional[List[str]]) -> Optional[List[re.Pattern[str]]]:
    if not values:
        return None
    out = []
    for v in values:
        if v.strip():
            out.append(re.compile(v))
    return out or None


def resolve_pod_to_workload(pod: Dict[str, Any], kubeconfig: Optional[str]) -> Optional[WorkloadRef]:
    ns = pod.get("metadata", {}).get("namespace")
    if not ns:
        return None

    owners = pod.get("metadata", {}).get("ownerReferences") or []
    if not owners:
        return None
    owner = owners[0]
    kind = owner.get("kind")
    name = owner.get("name")
    if not kind or not name:
        return None

    if kind in ("DaemonSet", "StatefulSet"):
        return WorkloadRef(namespace=ns, kind=kind, name=name)

    if kind == "ReplicaSet":
        rs = run_kubectl_json(["get", "replicaset", name, "-n", ns], kubeconfig)
        rs_owners = rs.get("metadata", {}).get("ownerReferences") or []
        if not rs_owners:
            return WorkloadRef(namespace=ns, kind="ReplicaSet", name=name)
        rs_owner = rs_owners[0]
        rs_kind = rs_owner.get("kind")
        rs_name = rs_owner.get("name")
        if rs_kind == "Deployment" and rs_name:
            return WorkloadRef(namespace=ns, kind="Deployment", name=rs_name)
        return WorkloadRef(namespace=ns, kind=rs_kind or "ReplicaSet", name=rs_name or name)

    if kind == "Job":
        return None

    return WorkloadRef(namespace=ns, kind=kind, name=name)


def workload_resource(kind: str) -> str:
    mapping = {
        "Deployment": "deployment",
        "StatefulSet": "statefulset",
        "DaemonSet": "daemonset",
        "ReplicaSet": "replicaset",
    }
    if kind not in mapping:
        raise ValueError(f"Unsupported workload kind: {kind}")
    return mapping[kind]


def get_pod_template_containers(workload: Dict[str, Any]) -> List[Dict[str, Any]]:
    spec = workload.get("spec", {})
    tmpl = spec.get("template", {})
    pod_spec = tmpl.get("spec", {})
    return pod_spec.get("containers") or []


def build_json_patch_for_container_memory_limit(
    workload_kind: str,
    container_index: int,
    memory: str,
    has_resources: bool,
    has_limits: bool,
    has_memory: bool,
) -> List[Dict[str, Any]]:
    if workload_kind not in ("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet"):
        raise ValueError(f"Unsupported workload kind: {workload_kind}")

    base = f"/spec/template/spec/containers/{container_index}"
    ops: List[Dict[str, Any]] = []

    if not has_resources:
        ops.append({"op": "add", "path": base + "/resources", "value": {}})
    if not has_limits:
        ops.append({"op": "add", "path": base + "/resources/limits", "value": {}})

    ops.append(
        {
            "op": "replace" if has_memory else "add",
            "path": base + "/resources/limits/memory",
            "value": memory,
        }
    )
    return ops


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Apply memory requests as memory limits; patches controller pod templates."
    )
    parser.add_argument(
        "--kubeconfig",
        default=os.environ.get("KUBECONFIG"),
        help="Path to kubeconfig (defaults to $KUBECONFIG).",
    )
    parser.add_argument(
        "--namespaces",
        "--namespace",
        help="Comma-separated namespace allowlist (default: all).",
    )
    parser.add_argument(
        "--exclude-namespaces",
        help="Comma-separated namespace denylist.",
    )
    parser.add_argument(
        "--pod",
        action="append",
        default=[],
        help="Pod to target (format: ns/pod or pod with --namespaces=<ns>). Can be repeated.",
    )
    parser.add_argument(
        "--workload",
        action="append",
        default=[],
        help="Workload to target (format: ns/Kind/name or Kind/name with --namespaces=<ns>). Can be repeated.",
    )
    parser.add_argument(
        "--container",
        action="append",
        default=[],
        help="Container name regex to include (repeatable). Default: all containers.",
    )
    parser.add_argument(
        "--include-istio-proxy",
        action="store_true",
        help="Include istio-proxy container (default: skipped).",
    )
    parser.add_argument(
        "--allow-decrease-limit",
        action="store_true",
        help="Allow decreasing an existing memory limit down to the request (default: skip decreases).",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Actually patch workloads. Default is dry-run (prints intended changes).",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print extra details.",
    )
    parser.add_argument(
        "--print-issues-immediately",
        action="store_true",
        help="Print warnings/errors as they are encountered (default: print them at the end).",
    )
    parser.add_argument(
        "--issues-max",
        type=int,
        default=200,
        help="Max number of warning/error details to print at the end (default: 200). Use 0 to show all.",
    )
    parser.add_argument(
        "--color",
        choices=["auto", "always", "never"],
        default="auto",
        help="Colorize warning/error output (default: auto).",
    )

    args = parser.parse_args()
    issues = IssueCollector(
        color_mode=args.color,
        max_details=args.issues_max,
        print_immediately=args.print_issues_immediately,
    )

    ns_allow = parse_namespace_list(args.namespaces)
    ns_deny = parse_namespace_list(args.exclude_namespaces)
    container_patterns = build_regex_list(args.container)

    if ns_allow and len(ns_allow) == 1:
        single_ns = next(iter(ns_allow))
    else:
        single_ns = None

    explicit_targets: Set[WorkloadRef] = set()

    for w in args.workload:
        parts = [p for p in w.split("/") if p]
        if len(parts) == 3:
            ns, kind, name = parts
        elif len(parts) == 2 and single_ns:
            kind, name = parts
            ns = single_ns
        else:
            eprint(f"invalid --workload '{w}' (use ns/Kind/name or Kind/name with --namespaces=<ns>)")
            return 2
        explicit_targets.add(WorkloadRef(namespace=ns, kind=kind, name=name))

    for p in args.pod:
        parts = [x for x in p.split("/") if x]
        if len(parts) == 2:
            ns, pod_name = parts
        elif len(parts) == 1 and single_ns:
            ns = single_ns
            pod_name = parts[0]
        else:
            eprint(f"invalid --pod '{p}' (use ns/pod or pod with --namespaces=<ns>)")
            return 2
        pod = run_kubectl_json(["get", "pod", pod_name, "-n", ns], args.kubeconfig)
        wref = resolve_pod_to_workload(pod, args.kubeconfig)
        if not wref:
            issues.warn("pod_no_supported_owner", f"skip pod {ns}/{pod_name}: no supported controller owner (job/standalone?)")
            continue
        explicit_targets.add(wref)

    targets: List[WorkloadRef] = []
    if explicit_targets:
        targets = sorted(explicit_targets, key=lambda w: (w.namespace, w.kind, w.name))
    else:
        for kind, res in (("Deployment", "deployments"), ("StatefulSet", "statefulsets"), ("DaemonSet", "daemonsets")):
            objs = run_kubectl_json(["get", res, "-A"], args.kubeconfig)
            for item in objs.get("items") or []:
                ns = (item.get("metadata") or {}).get("namespace")
                name = (item.get("metadata") or {}).get("name")
                if not ns or not name:
                    continue
                if ns_allow and ns not in ns_allow:
                    continue
                if ns_deny and ns in ns_deny:
                    continue
                targets.append(WorkloadRef(namespace=ns, kind=kind, name=name))

        targets.sort(key=lambda w: (w.namespace, w.kind, w.name))

    total_patched = 0
    total_skipped = 0

    for wref in targets:
        if wref.kind not in ("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet"):
            total_skipped += 1
            continue

        try:
            workload = run_kubectl_json(
                ["get", workload_resource(wref.kind), wref.name, "-n", wref.namespace],
                args.kubeconfig,
            )
        except subprocess.CalledProcessError as ex:
            issues.warn("workload_fetch_failed", f"skip {wref.namespace}/{wref.kind}/{wref.name}: failed to fetch ({ex})")
            total_skipped += 1
            continue

        containers = get_pod_template_containers(workload)
        if not containers:
            total_skipped += 1
            continue

        ops: List[Dict[str, Any]] = []
        any_change = False

        for idx, c in enumerate(containers):
            cname = c.get("name")
            if not isinstance(cname, str) or not cname.strip():
                continue
            if cname == "istio-proxy" and not args.include_istio_proxy:
                continue
            if not match_any(cname, container_patterns):
                continue

            res = c.get("resources") or {}
            req = res.get("requests") or {}
            lim = res.get("limits") or {}
            req_mem = req.get("memory")
            lim_mem = lim.get("memory")

            if not isinstance(req_mem, str) or not req_mem.strip():
                issues.warn("missing_memory_request", f"skip {wref.namespace}/{wref.kind}/{wref.name}:{cname}: missing memory request")
                total_skipped += 1
                continue

            req_bytes = parse_bytes(req_mem)
            if req_bytes is None:
                issues.warn(
                    "unparseable_memory_request",
                    f"skip {wref.namespace}/{wref.kind}/{wref.name}:{cname}: unparseable memory request '{req_mem}'",
                )
                total_skipped += 1
                continue

            has_limit = isinstance(lim_mem, str) and lim_mem.strip() != ""
            if has_limit:
                lim_bytes = parse_bytes(str(lim_mem))
                if lim_bytes is None:
                    issues.warn(
                        "unparseable_memory_limit",
                        f"skip {wref.namespace}/{wref.kind}/{wref.name}:{cname}: unparseable memory limit '{lim_mem}'",
                    )
                    total_skipped += 1
                    continue
                if lim_bytes == req_bytes:
                    continue
                if lim_bytes > req_bytes and not args.allow_decrease_limit:
                    issues.warn(
                        "would_decrease_limit",
                        f"skip {wref.namespace}/{wref.kind}/{wref.name}:{cname}: "
                        f"would decrease memory limit {lim_mem} -> {req_mem} (use --allow-decrease-limit to override)",
                    )
                    total_skipped += 1
                    continue

            has_resources = isinstance(c.get("resources"), dict)
            has_limits_obj = has_resources and isinstance((c.get("resources") or {}).get("limits"), dict)
            lim_obj = (c.get("resources") or {}).get("limits") if has_limits_obj else {}
            has_memory = has_limits_obj and isinstance(lim_obj, dict) and "memory" in lim_obj

            ops.extend(
                build_json_patch_for_container_memory_limit(
                    wref.kind,
                    idx,
                    memory=req_mem,
                    has_resources=has_resources,
                    has_limits=has_limits_obj,
                    has_memory=has_memory,
                )
            )
            any_change = True

            if args.verbose or not args.apply:
                eprint(
                    f"{'apply' if args.apply else 'plan'} {wref.namespace}/{wref.kind}/{wref.name}:{cname} "
                    f"mem limit {lim_mem or '-'} -> {req_mem}"
                )

        if not any_change:
            continue

        total_patched += 1
        if not args.apply:
            print(
                json.dumps(
                    {
                        "namespace": wref.namespace,
                        "kind": wref.kind,
                        "name": wref.name,
                        "patchType": "json",
                        "patch": ops,
                    },
                    indent=2,
                    sort_keys=True,
                )
            )
            continue

        try:
            run_kubectl(
                [
                    "patch",
                    workload_resource(wref.kind),
                    wref.name,
                    "-n",
                    wref.namespace,
                    "--type",
                    "json",
                    "-p",
                    json.dumps(ops, separators=(",", ":")),
                ],
                args.kubeconfig,
            )
        except subprocess.CalledProcessError as ex:
            issues.error("patch_failed", f"failed to patch {wref.namespace}/{wref.kind}/{wref.name}: {ex}")
            return 1

    issues.print_summary()
    eprint(f"patched_workloads={total_patched} skipped_items={total_skipped} mode={'apply' if args.apply else 'dry-run'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
