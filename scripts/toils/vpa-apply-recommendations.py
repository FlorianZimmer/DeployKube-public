#!/usr/bin/env python3

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set, Tuple


def eprint(*args: object) -> None:
    print(*args, file=sys.stderr)


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

        # Print details (bounded).
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


def _collect_kubectl_warnings(proc: subprocess.CompletedProcess[str], issues: Optional["IssueCollector"]) -> None:
    if not issues or not proc.stderr:
        return
    for line in proc.stderr.splitlines():
        s = line.strip()
        if not s:
            continue
        if s.startswith("Warning:"):
            issues.warn("kubectl_warning", s[len("Warning:") :].strip())


def run_kubectl_json(args: Sequence[str], kubeconfig: Optional[str], *, issues: Optional["IssueCollector"] = None) -> Any:
    cmd = ["kubectl"]
    if kubeconfig:
        cmd += ["--kubeconfig", kubeconfig]
    cmd += list(args) + ["-o", "json"]
    proc = subprocess.run(cmd, text=True, capture_output=True, check=False)
    _collect_kubectl_warnings(proc, issues)
    if proc.returncode != 0:
        raise subprocess.CalledProcessError(proc.returncode, cmd, output=proc.stdout, stderr=proc.stderr)
    return json.loads(proc.stdout)


def run_kubectl(args: Sequence[str], kubeconfig: Optional[str], *, issues: Optional["IssueCollector"] = None) -> str:
    cmd = ["kubectl"]
    if kubeconfig:
        cmd += ["--kubeconfig", kubeconfig]
    cmd += list(args)
    proc = subprocess.run(cmd, text=True, capture_output=True, check=False)
    _collect_kubectl_warnings(proc, issues)
    if proc.returncode != 0:
        raise subprocess.CalledProcessError(proc.returncode, cmd, output=proc.stdout, stderr=proc.stderr)
    return proc.stdout


CPU_MILLI_FACTOR = Decimal(1000)


def parse_cpu_millicores(quantity: str) -> Optional[int]:
    q = quantity.strip()
    if q == "":
        return None
    try:
        if q.endswith("m"):
            return int(Decimal(q[:-1]))
        return int((Decimal(q) * CPU_MILLI_FACTOR).to_integral_value(rounding="ROUND_FLOOR"))
    except (InvalidOperation, ValueError):
        return None


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


def json_pointer_escape(segment: str) -> str:
    return segment.replace("~", "~0").replace("/", "~1")


def format_cpu_millicores(millicores: int) -> str:
    return f"{millicores}m"


def format_bytes(quantity_bytes: int, unit: str) -> str:
    if unit == "bytes":
        return str(quantity_bytes)
    if unit not in _BINARY_UNITS:
        raise ValueError(f"unsupported memory unit: {unit}")
    factor = _BINARY_UNITS[unit]
    # Round up to avoid decreasing due to formatting.
    v = (quantity_bytes + factor - 1) // factor
    return f"{v}{unit}"


def normalize_cpu_quantity(quantity: str) -> Optional[str]:
    mc = parse_cpu_millicores(quantity)
    if mc is None:
        return None
    return format_cpu_millicores(mc)


def normalize_memory_quantity(quantity: str, memory_unit: str) -> Optional[str]:
    b = parse_bytes(quantity)
    if b is None:
        return None
    return format_bytes(b, memory_unit)


def format_bytes_human(quantity_bytes: int) -> str:
    b = float(quantity_bytes)
    if abs(b) < 1024:
        return f"{quantity_bytes} B"
    kib = b / 1024.0
    if abs(kib) < 1024:
        return f"{kib:.2f} KiB"
    mib = kib / 1024.0
    if abs(mib) < 1024:
        return f"{mib:.2f} MiB"
    gib = mib / 1024.0
    if abs(gib) < 1024:
        return f"{gib:.2f} GiB"
    tib = gib / 1024.0
    return f"{tib:.2f} TiB"


def format_cpu_human(millicores: int) -> str:
    return f"{millicores}m ({millicores/1000.0:.3f} cores)"


def format_ratio(numer: int, denom: int) -> str:
    if denom <= 0:
        return "n/a"
    return f"{(100.0 * numer / denom):.1f}%"


def git_repo_root() -> str:
    try:
        out = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
    except subprocess.CalledProcessError as ex:
        raise RuntimeError("failed to determine git repo root (run inside a git worktree?)") from ex
    if not out:
        raise RuntimeError("failed to determine git repo root (empty output)")
    return out


def resolve_gitops_root(repo_root: str, gitops_root_flag: Optional[str]) -> str:
    if gitops_root_flag:
        return os.path.abspath(gitops_root_flag)
    return os.path.join(repo_root, "platform", "gitops")


def resolve_gitops_app_dir(repo_root: str, gitops_root: str, app_path: str) -> Optional[str]:
    p = app_path.strip().lstrip("/")
    if not p:
        return None

    # Argo paths are usually relative to repo root; sometimes they are relative to platform/gitops.
    candidates = [
        os.path.join(repo_root, p),
        os.path.join(gitops_root, p),
    ]
    for c in candidates:
        if os.path.isdir(c) and os.path.isfile(os.path.join(c, "kustomization.yaml")):
            return c
    for c in candidates:
        if os.path.isdir(c):
            return c
    return None


def prompt_confirm(message: str, *, assume_yes: bool) -> bool:
    if assume_yes:
        return True
    if not sys.stdin.isatty():
        return False
    try:
        ans = input(f"{message} Type 'yes' to continue: ").strip().lower()
    except EOFError:
        return False
    return ans == "yes"


def kustomization_add_patch(kustomization_path: str, patch_rel_path: str) -> bool:
    """
    Ensure kustomization.yaml references patch_rel_path (relative to the kustomization dir).

    Returns True if the file changed.
    """
    with open(kustomization_path, "r", encoding="utf-8") as f:
        text = f.read()

    # Idempotency: already present.
    if (
        re.search(rf"(?m)^\s*path:\s*{re.escape(patch_rel_path)}\s*$", text)
        or re.search(rf"(?m)^\s*-\s*path:\s*{re.escape(patch_rel_path)}\s*$", text)
        or re.search(rf"(?m)^\s*-\s*{re.escape(patch_rel_path)}\s*$", text)
    ):
        return False

    lines = text.splitlines(True)

    def find_key(key: str) -> Optional[int]:
        pat = re.compile(rf"^{re.escape(key)}:\s*(#.*)?$")
        for i, line in enumerate(lines):
            if pat.match(line.rstrip("\n")):
                return i
        return None

    def find_block_end(start_idx: int) -> int:
        # Block ends at the next top-level key or EOF.
        j = start_idx + 1
        while j < len(lines):
            s = lines[j]
            if s.strip() == "":
                j += 1
                continue
            if s.startswith(" ") or s.startswith("\t"):
                j += 1
                continue
            if s.lstrip().startswith("#"):
                # Top-level comment breaks the block.
                break
            break
        return j

    patches_idx = find_key("patches")
    if patches_idx is not None:
        end = find_block_end(patches_idx)
        entry = f"  - path: {patch_rel_path}\n"
        lines.insert(end, entry)
        with open(kustomization_path, "w", encoding="utf-8") as f:
            f.write("".join(lines))
        return True

    psm_idx = find_key("patchesStrategicMerge")
    if psm_idx is not None:
        end = find_block_end(psm_idx)
        entry = f"  - {patch_rel_path}\n"
        lines.insert(end, entry)
        with open(kustomization_path, "w", encoding="utf-8") as f:
            f.write("".join(lines))
        return True

    # No patches section; append one at the end (keep trailing newline if present).
    trailer = "" if text.endswith("\n") else "\n"
    addition = f"{trailer}patches:\n  - path: {patch_rel_path}\n"
    with open(kustomization_path, "w", encoding="utf-8") as f:
        f.write(text + addition)
    return True


def render_vpa_requests_patch_yaml(
    wref: "WorkloadRef",
    per_container: Dict[str, Dict[str, Dict[str, str]]],
) -> str:
    # Strategic merge patch: containers merge by name.
    lines: List[str] = []
    lines.append("apiVersion: apps/v1\n")
    lines.append(f"kind: {wref.kind}\n")
    lines.append("metadata:\n")
    lines.append(f"  name: {wref.name}\n")
    lines.append(f"  namespace: {wref.namespace}\n")
    lines.append("spec:\n")
    lines.append("  template:\n")
    lines.append("    spec:\n")
    lines.append("      containers:\n")

    for cname in sorted(per_container.keys()):
        resources = per_container[cname]
        req = resources.get("requests") or {}
        lim = resources.get("limits") or {}
        lines.append(f"        - name: {cname}\n")
        lines.append("          resources:\n")
        if req:
            lines.append("            requests:\n")
            if "cpu" in req:
                lines.append(f"              cpu: \"{req['cpu']}\"\n")
            if "memory" in req:
                lines.append(f"              memory: \"{req['memory']}\"\n")
        if lim:
            lines.append("            limits:\n")
            if "memory" in lim:
                lines.append(f"              memory: \"{lim['memory']}\"\n")

    return "".join(lines)


@dataclass(frozen=True)
class ClusterCapacity:
    alloc_cpu_m: int
    alloc_mem_bytes: int
    max_node_cpu_m: int
    max_node_mem_bytes: int
    req_cpu_m: int
    req_mem_bytes: int

    @property
    def headroom_cpu_m(self) -> int:
        return max(0, self.alloc_cpu_m - self.req_cpu_m)

    @property
    def headroom_mem_bytes(self) -> int:
        return max(0, self.alloc_mem_bytes - self.req_mem_bytes)


def get_cluster_capacity(kubeconfig: Optional[str]) -> ClusterCapacity:
    nodes = run_kubectl_json(["get", "nodes"], kubeconfig)
    alloc_cpu_m = 0
    alloc_mem_bytes = 0
    max_node_cpu_m = 0
    max_node_mem_bytes = 0

    for n in nodes.get("items") or []:
        alloc = (n.get("status") or {}).get("allocatable") or {}
        cpu = parse_cpu_millicores(str(alloc.get("cpu", "")))
        mem = parse_bytes(str(alloc.get("memory", "")))
        if cpu is None or mem is None:
            continue
        alloc_cpu_m += cpu
        alloc_mem_bytes += mem
        max_node_cpu_m = max(max_node_cpu_m, cpu)
        max_node_mem_bytes = max(max_node_mem_bytes, mem)

    pods = run_kubectl_json(["get", "pods", "-A"], kubeconfig)
    req_cpu_m = 0
    req_mem_bytes = 0

    for p in pods.get("items") or []:
        phase = ((p.get("status") or {}).get("phase") or "").strip()
        if phase not in ("Running", "Pending"):
            continue
        spec = p.get("spec") or {}
        for c in spec.get("containers") or []:
            res = c.get("resources") or {}
            req = res.get("requests") or {}
            cpu_q = req.get("cpu")
            mem_q = req.get("memory")
            if isinstance(cpu_q, str):
                cpu = parse_cpu_millicores(cpu_q)
                if cpu is not None:
                    req_cpu_m += cpu
            if isinstance(mem_q, str):
                mem = parse_bytes(mem_q)
                if mem is not None:
                    req_mem_bytes += mem

    return ClusterCapacity(
        alloc_cpu_m=alloc_cpu_m,
        alloc_mem_bytes=alloc_mem_bytes,
        max_node_cpu_m=max_node_cpu_m,
        max_node_mem_bytes=max_node_mem_bytes,
        req_cpu_m=req_cpu_m,
        req_mem_bytes=req_mem_bytes,
    )


@dataclass(frozen=True)
class WorkloadRef:
    namespace: str
    kind: str
    name: str


def get_argocd_source_paths_by_workload(
    kubeconfig: Optional[str],
    *,
    argocd_namespace: str,
    issues: Optional["IssueCollector"] = None,
) -> Dict[WorkloadRef, str]:
    """
    Build an index of (ns, kind, name) -> Argo Application spec.source.path.

    This lets us backport drifted changes into the exact overlay path Argo is reconciling.
    """
    apps = run_kubectl_json(["get", "applications", "-n", argocd_namespace], kubeconfig, issues=issues)
    out: Dict[WorkloadRef, str] = {}

    for app in apps.get("items") or []:
        spec = app.get("spec") or {}

        src_path: Optional[str] = None
        if isinstance(spec.get("source"), dict):
            src_path = (spec.get("source") or {}).get("path")
        if not src_path and isinstance(spec.get("sources"), list):
            sources = spec.get("sources") or []
            paths = [s.get("path") for s in sources if isinstance(s, dict) and isinstance(s.get("path"), str)]
            if len(paths) == 1:
                src_path = paths[0]

        if not isinstance(src_path, str) or not src_path.strip():
            continue

        status = app.get("status") or {}
        for r in status.get("resources") or []:
            if not isinstance(r, dict):
                continue
            ns = r.get("namespace")
            kind = r.get("kind")
            name = r.get("name")
            if not (isinstance(ns, str) and isinstance(kind, str) and isinstance(name, str)):
                continue
            wref = WorkloadRef(namespace=ns, kind=kind, name=name)
            if wref not in out:
                out[wref] = src_path.strip()
    return out


def parse_namespace_list(csv: Optional[str]) -> Optional[Set[str]]:
    if not csv:
        return None
    out = set()
    for part in csv.split(","):
        p = part.strip()
        if p:
            out.add(p)
    return out or None


def parse_resource_list(csv: Optional[str]) -> Set[str]:
    # Default: apply both.
    if csv is None or csv.strip() == "":
        return {"cpu", "memory"}
    out: Set[str] = set()
    for part in csv.split(","):
        p = part.strip().lower()
        if not p:
            continue
        if p not in ("cpu", "memory"):
            raise ValueError(f"invalid resource '{p}' (expected cpu and/or memory)")
        out.add(p)
    if not out:
        raise ValueError("no resources selected (expected cpu and/or memory)")
    return out


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


def resolve_pod_to_workload(
    pod: Dict[str, Any], kubeconfig: Optional[str], *, issues: Optional["IssueCollector"] = None
) -> Optional[WorkloadRef]:
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
        rs = run_kubectl_json(["get", "replicaset", name, "-n", ns], kubeconfig, issues=issues)
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


def workload_api_group(kind: str) -> str:
    if kind in ("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet"):
        return "apps"
    return ""


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


def get_container_index(workload: Dict[str, Any], container_name: str) -> Optional[int]:
    containers = get_pod_template_containers(workload)
    for i, c in enumerate(containers):
        if c.get("name") == container_name:
            return i
    return None


def get_current_requests(workload: Dict[str, Any], container_index: int) -> Dict[str, str]:
    containers = get_pod_template_containers(workload)
    if container_index < 0 or container_index >= len(containers):
        return {}
    c = containers[container_index]
    res = c.get("resources") or {}
    req = res.get("requests") or {}
    out: Dict[str, str] = {}
    for k in ("cpu", "memory"):
        if k in req and isinstance(req[k], str):
            out[k] = req[k]
    return out


def get_current_limits(workload: Dict[str, Any], container_index: int) -> Dict[str, str]:
    containers = get_pod_template_containers(workload)
    if container_index < 0 or container_index >= len(containers):
        return {}
    c = containers[container_index]
    res = c.get("resources") or {}
    lim = res.get("limits") or {}
    out: Dict[str, str] = {}
    for k in ("cpu", "memory"):
        if k in lim and isinstance(lim[k], str):
            out[k] = lim[k]
    return out


def build_json_patch_for_container_resources(
    workload_kind: str,
    container_index: int,
    cpu_request: Optional[str],
    memory_request: Optional[str],
    memory_limit: Optional[str],
    has_resources: bool,
    has_requests: bool,
    has_limits: bool,
    has_cpu: bool,
    has_memory: bool,
    has_memory_limit: bool,
) -> List[Dict[str, Any]]:
    if workload_kind not in ("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet"):
        raise ValueError(f"Unsupported workload kind: {workload_kind}")

    base = f"/spec/template/spec/containers/{container_index}"
    ops: List[Dict[str, Any]] = []

    if not has_resources:
        ops.append({"op": "add", "path": base + "/resources", "value": {}})
    if not has_requests:
        ops.append({"op": "add", "path": base + "/resources/requests", "value": {}})
    if memory_limit is not None and not has_limits:
        ops.append({"op": "add", "path": base + "/resources/limits", "value": {}})

    if cpu_request is not None:
        ops.append(
            {
                "op": "replace" if has_cpu else "add",
                "path": base + "/resources/requests/cpu",
                "value": cpu_request,
            }
        )
    if memory_request is not None:
        ops.append(
            {
                "op": "replace" if has_memory else "add",
                "path": base + "/resources/requests/memory",
                "value": memory_request,
            }
        )
    if memory_limit is not None:
        ops.append(
            {
                "op": "replace" if has_memory_limit else "add",
                "path": base + "/resources/limits/memory",
                "value": memory_limit,
            }
        )
    return ops


def pick_reco_value(container_reco: Dict[str, Any], bound: str) -> Dict[str, str]:
    if bound not in ("lower", "target", "upper"):
        raise ValueError(f"invalid bound: {bound}")

    key = {"lower": "lowerBound", "target": "target", "upper": "upperBound"}[bound]
    value = container_reco.get(key) or {}
    out: Dict[str, str] = {}
    for k in ("cpu", "memory"):
        v = value.get(k)
        if isinstance(v, str) and v.strip():
            out[k] = v.strip()
    return out


def safe_to_apply(
    current: Optional[str], recommended: str, resource: str, allow_decrease: bool
) -> Tuple[bool, str]:
    if allow_decrease:
        return True, "allow-decrease"

    if current is None or current.strip() == "":
        return True, "no-current"

    if resource == "cpu":
        cur = parse_cpu_millicores(current)
        rec = parse_cpu_millicores(recommended)
        unit = "m"
    elif resource == "memory":
        cur = parse_bytes(current)
        rec = parse_bytes(recommended)
        unit = "bytes"
    else:
        return False, "unknown-resource"

    if cur is None or rec is None:
        return False, f"unparseable ({current} -> {recommended})"
    if rec < cur:
        return False, f"would-decrease ({rec}{unit} < {cur}{unit})"
    return True, "ok"


def would_exceed_limit(request: str, limit: str, resource: str) -> Optional[bool]:
    if resource == "cpu":
        req = parse_cpu_millicores(request)
        lim = parse_cpu_millicores(limit)
    elif resource == "memory":
        req = parse_bytes(request)
        lim = parse_bytes(limit)
    else:
        return None
    if req is None or lim is None:
        return None
    return req > lim


def request_limit_ratio(request: str, limit: str, resource: str) -> Optional[float]:
    if resource == "cpu":
        req = parse_cpu_millicores(request)
        lim = parse_cpu_millicores(limit)
    elif resource == "memory":
        req = parse_bytes(request)
        lim = parse_bytes(limit)
    else:
        return None
    if req is None or lim is None or lim == 0:
        return None
    return float(Decimal(req) / Decimal(lim))


def compute_memory_limit_with_headroom(
    memory_request: str,
    *,
    headroom_of_limit: float,
    min_headroom_bytes: int,
    memory_unit: str,
) -> Optional[str]:
    req_b = parse_bytes(memory_request)
    if req_b is None or req_b <= 0:
        return None

    # Headroom as a fraction of the resulting limit:
    #   headroom = limit - request
    #   headroom/limit = p
    # => request = (1-p)*limit => limit = request/(1-p)
    p = Decimal(str(headroom_of_limit))
    if p < Decimal("0.0"):
        p = Decimal("0.0")
    if p >= Decimal("0.95"):
        # Guardrail: avoid absurd multiplier (>=20x).
        p = Decimal("0.95")

    denom = Decimal("1.0") - p
    ratio = (Decimal("1.0") / denom) if denom > 0 else Decimal("20.0")
    target_b = int((Decimal(req_b) * ratio).to_integral_value(rounding="ROUND_CEILING"))
    limit_b = max(target_b, req_b + int(min_headroom_bytes))
    if limit_b < req_b:
        limit_b = req_b

    return format_bytes(limit_b, memory_unit)


def normalize_memory_quantity_or_none(quantity: Optional[str], memory_unit: str) -> Optional[str]:
    if quantity is None:
        return None
    q = quantity.strip()
    if q == "":
        return None
    return normalize_memory_quantity(q, memory_unit)


@dataclass(frozen=True)
class PlanTotals:
    workloads: int
    container_changes: int
    cpu_delta_m: int
    mem_delta_bytes: int
    max_pod_cpu_m_after: int
    max_pod_mem_bytes_after: int


def summarize_plan(
    plan_per_workload: Dict[WorkloadRef, Dict[str, int]],
) -> PlanTotals:
    workloads = 0
    container_changes = 0
    cpu_delta_m = 0
    mem_delta_bytes = 0
    max_pod_cpu_m_after = 0
    max_pod_mem_bytes_after = 0

    for wref, d in plan_per_workload.items():
        workloads += 1
        container_changes += d.get("container_changes", 0)
        cpu_delta_m += d.get("cpu_delta_m", 0)
        mem_delta_bytes += d.get("mem_delta_bytes", 0)
        max_pod_cpu_m_after = max(max_pod_cpu_m_after, d.get("pod_cpu_m_after", 0))
        max_pod_mem_bytes_after = max(max_pod_mem_bytes_after, d.get("pod_mem_bytes_after", 0))

    return PlanTotals(
        workloads=workloads,
        container_changes=container_changes,
        cpu_delta_m=cpu_delta_m,
        mem_delta_bytes=mem_delta_bytes,
        max_pod_cpu_m_after=max_pod_cpu_m_after,
        max_pod_mem_bytes_after=max_pod_mem_bytes_after,
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Apply VPA recommendation bounds to workload container requests (patches controllers; VPA stays updateMode: Off)."
    )
    parser.add_argument(
        "--kubeconfig",
        default=os.environ.get("KUBECONFIG"),
        help="Path to kubeconfig (defaults to $KUBECONFIG).",
    )
    parser.add_argument(
        "--bound",
        choices=["lower", "target", "upper"],
        default="target",
        help="Which VPA recommendation bound to apply.",
    )
    parser.add_argument(
        "--resources",
        default="cpu,memory",
        help="Comma-separated resources to apply (cpu,memory). Default: cpu,memory.",
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
        help="Container name regex to include (repeatable). Default: all containers present in VPA recommendation.",
    )
    parser.add_argument(
        "--include-istio-proxy",
        action="store_true",
        help="Include istio-proxy container (default: skipped).",
    )
    parser.add_argument(
        "--allow-decrease",
        action="store_true",
        help="Allow decreasing requests below current values (default: never decrease).",
    )
    parser.add_argument(
        "--allow-request-above-limit",
        action="store_true",
        help="Allow setting a request above the current container limit (default: never exceed limit).",
    )
    parser.add_argument(
        "--memory-unit",
        choices=["bytes", "Ki", "Mi", "Gi"],
        default="Mi",
        help="Format memory requests using this unit (default: Mi).",
    )
    parser.add_argument(
        "--warn-request-limit-ratio",
        type=float,
        default=0.9,
        help="Warn if request/limit ratio is >= this value (default: 0.9). Set to 0 to disable warnings.",
    )
    parser.add_argument(
        "--set-memory-limit",
        action="store_true",
        help=(
            "Also set memory limits. Limit is derived from the chosen VPA memory request bound plus headroom. "
            "Default: off (requests-only)."
        ),
    )
    parser.add_argument(
        "--memory-limit-mode",
        choices=["headroom", "equal-request"],
        default="headroom",
        help=(
            "When using --set-memory-limit, choose how to compute limits. "
            "'headroom' uses the headroom percent/min knobs; 'equal-request' sets limit.memory=request.memory."
        ),
    )
    parser.add_argument(
        "--memory-limit-headroom-percent-of-limit",
        type=float,
        default=20.0,
        help=(
            "Headroom as a percent of the resulting memory limit (default: 20). "
            "Example: 20 => limit = request / 0.8 (i.e., 1.25x request)."
        ),
    )
    parser.add_argument(
        "--memory-limit-min-headroom",
        default="32Mi",
        help="Minimum extra memory to add when computing a memory limit (default: 32Mi).",
    )
    parser.add_argument(
        "--allow-decrease-memory-limit",
        action="store_true",
        help="Allow decreasing memory limits (default: never decrease limits; only raise or add).",
    )
    parser.add_argument(
        "--no-check-fit-on-node",
        action="store_true",
        help="Disable the safety check that ensures per-pod requests fit on at least one node.",
    )
    parser.add_argument(
        "--no-check-cluster-headroom",
        action="store_true",
        help="Disable the safety check that ensures total increases fit in cluster headroom (allocatable - requested).",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="Actually patch workloads. Default is dry-run (prints intended changes).",
    )
    parser.add_argument(
        "--backport-gitops",
        action="store_true",
        help=(
            "Write Kustomize patches into the local GitOps repo after planning/applying, so Argo won't revert the "
            "change. Uses Argo Application status to map workloads to source paths."
        ),
    )
    parser.add_argument(
        "--backport-include-unchanged",
        action="store_true",
        help=(
            "When backporting, also write the computed target values even if they already match the live workload "
            "(useful when you already applied changes but Git still lags)."
        ),
    )
    parser.add_argument(
        "--gitops-root",
        default=None,
        help="Path to platform/gitops (default: <repo-root>/platform/gitops).",
    )
    parser.add_argument(
        "--argocd-namespace",
        default="argocd",
        help="Namespace where Argo CD Applications live (default: argocd).",
    )
    parser.add_argument(
        "--rollout-timeout",
        default="10m",
        help="Timeout passed to kubectl rollout status when backporting (default: 10m).",
    )
    parser.add_argument(
        "--no-rollout-wait",
        action="store_true",
        help="Skip waiting for rollout success before backporting (not recommended).",
    )
    parser.add_argument(
        "--yes",
        action="store_true",
        help="Assume 'yes' for prompts (non-interactive safe automation).",
    )
    parser.add_argument(
        "--summary-only",
        action="store_true",
        help="In dry-run mode, suppress per-workload JSON patches and per-container plan lines; print only summaries.",
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

    min_headroom_b = parse_bytes(args.memory_limit_min_headroom)
    if min_headroom_b is None:
        eprint(f"invalid --memory-limit-min-headroom '{args.memory_limit_min_headroom}'")
        return 2
    if args.memory_limit_headroom_percent_of_limit < 0.0 or args.memory_limit_headroom_percent_of_limit >= 95.0:
        eprint("invalid --memory-limit-headroom-percent-of-limit (must be >= 0 and < 95)")
        return 2

    try:
        resources_to_apply = parse_resource_list(args.resources)
    except ValueError as ex:
        eprint(f"invalid --resources: {ex}")
        return 2

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
        pod = run_kubectl_json(["get", "pod", pod_name, "-n", ns], args.kubeconfig, issues=issues)
        wref = resolve_pod_to_workload(pod, args.kubeconfig, issues=issues)
        if not wref:
            eprint(f"skip pod {ns}/{pod_name}: no supported controller owner (job/standalone?)")
            continue
        explicit_targets.add(wref)

    vpas = run_kubectl_json(["get", "vpa", "-A"], args.kubeconfig, issues=issues)
    vpa_items = vpas.get("items") or []

    # Map workloadRef -> per-container reco dict.
    vpa_by_target: Dict[WorkloadRef, Dict[str, Dict[str, str]]] = {}

    for vpa in vpa_items:
        meta = vpa.get("metadata", {})
        ns = meta.get("namespace")
        if not ns:
            continue
        if ns_allow and ns not in ns_allow:
            continue
        if ns_deny and ns in ns_deny:
            continue

        spec = vpa.get("spec", {})
        tr = spec.get("targetRef", {})
        kind = tr.get("kind")
        name = tr.get("name")
        if not kind or not name:
            continue

        wref = WorkloadRef(namespace=ns, kind=kind, name=name)
        if explicit_targets and wref not in explicit_targets:
            continue

        status = vpa.get("status", {}) or {}
        reco = status.get("recommendation", {}) or {}
        recos = reco.get("containerRecommendations") or []
        if not recos:
            continue

        containers: Dict[str, Dict[str, str]] = {}
        for cr in recos:
            cname = cr.get("containerName")
            if not isinstance(cname, str) or not cname.strip():
                continue
            if cname == "istio-proxy" and not args.include_istio_proxy:
                continue
            if not match_any(cname, container_patterns):
                continue
            picked = pick_reco_value(cr, args.bound)
            if picked:
                # Normalize into stable, human-friendly quantities (bytes -> Mi by default).
                normalized: Dict[str, str] = {}
                if "cpu" in picked:
                    cpu_norm = normalize_cpu_quantity(picked["cpu"])
                    if cpu_norm is not None:
                        normalized["cpu"] = cpu_norm
                if "memory" in picked:
                    mem_norm = normalize_memory_quantity(picked["memory"], args.memory_unit)
                    if mem_norm is not None:
                        normalized["memory"] = mem_norm
                if normalized:
                    containers[cname] = normalized
        if not containers:
            continue
        vpa_by_target[wref] = containers

    if explicit_targets and not vpa_by_target:
        eprint("No matching VPA recommendations found for the specified targets.")
        return 1

    if not explicit_targets and not vpa_by_target:
        eprint("No VPA recommendations found (are VPAs present and have they produced status yet?)")
        return 1

    check_fit_on_node = not args.no_check_fit_on_node
    check_cluster_headroom = not args.no_check_cluster_headroom

    # We use capacity for safety checks and end-of-run summaries. This is intentionally
    # computed even in dry-run so multi-change runs can be evaluated safely.
    capacity: Optional[ClusterCapacity] = get_cluster_capacity(args.kubeconfig)
    if args.verbose:
        eprint(
            "cluster capacity (allocatable / requested / headroom): "
            f"cpu={capacity.alloc_cpu_m}m/{capacity.req_cpu_m}m/{capacity.headroom_cpu_m}m "
            f"mem={capacity.alloc_mem_bytes}B/{capacity.req_mem_bytes}B/{capacity.headroom_mem_bytes}B"
        )

    # We compute a first-pass plan summary for multi-change runs (and to apply headroom checks
    # based on what would actually be changed after per-container safety gates).
    planned_stats: Dict[WorkloadRef, Dict[str, int]] = {}
    planned_patches: List[Tuple[WorkloadRef, List[Dict[str, Any]]]] = []
    backport_resources: Dict[WorkloadRef, Dict[str, Dict[str, Dict[str, str]]]] = {}

    total_patched = 0
    total_skipped = 0

    for wref, per_container in sorted(vpa_by_target.items(), key=lambda x: (x[0].namespace, x[0].kind, x[0].name)):
        if args.verbose:
            eprint(f"workload {wref.namespace}/{wref.kind}/{wref.name}")

        if wref.kind not in ("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet"):
            eprint(f"skip {wref.namespace}/{wref.kind}/{wref.name}: unsupported kind")
            total_skipped += 1
            continue

        try:
            workload = run_kubectl_json(
                ["get", workload_resource(wref.kind), wref.name, "-n", wref.namespace],
                args.kubeconfig,
                issues=issues,
            )
        except subprocess.CalledProcessError as ex:
            eprint(f"skip {wref.namespace}/{wref.kind}/{wref.name}: failed to fetch ({ex})")
            total_skipped += 1
            continue

        containers = get_pod_template_containers(workload)
        if not containers:
            eprint(f"skip {wref.namespace}/{wref.kind}/{wref.name}: no containers")
            total_skipped += 1
            continue

        # Compute current pod-level requests (requests may be absent; treat missing as 0 for totals).
        pod_cpu_m_before = 0
        pod_mem_b_before = 0
        for c in containers:
            req = (c.get("resources") or {}).get("requests") or {}
            cpu_q = req.get("cpu")
            mem_q = req.get("memory")
            if isinstance(cpu_q, str):
                v = parse_cpu_millicores(cpu_q)
                if v is not None:
                    pod_cpu_m_before += v
            if isinstance(mem_q, str):
                v = parse_bytes(mem_q)
                if v is not None:
                    pod_mem_b_before += v

        ops: List[Dict[str, Any]] = []
        any_change = False
        cpu_delta_m = 0
        mem_delta_b = 0
        container_changes = 0

        for cname, reco_values in per_container.items():
            idx = get_container_index(workload, cname)
            if idx is None:
                eprint(f"skip {wref.namespace}/{wref.kind}/{wref.name}:{cname}: container not found")
                total_skipped += 1
                continue

            current = get_current_requests(workload, idx)
            limits = get_current_limits(workload, idx)
            cur_cpu = current.get("cpu")
            cur_mem = current.get("memory")
            lim_cpu = limits.get("cpu")
            lim_mem = limits.get("memory")

            rec_cpu = reco_values.get("cpu")
            rec_mem = reco_values.get("memory")

            if "cpu" not in resources_to_apply:
                rec_cpu = None
            if "memory" not in resources_to_apply:
                rec_mem = None

            apply_cpu = None
            apply_mem = None
            apply_mem_limit = None

            desired_cpu = None
            desired_mem = None
            desired_mem_limit = None

            if rec_cpu is not None:
                ok, reason = safe_to_apply(cur_cpu, rec_cpu, "cpu", args.allow_decrease)
                if ok:
                    desired_cpu = rec_cpu
                elif args.verbose:
                    eprint(f"skip {wref.namespace}/{wref.kind}/{wref.name}:{cname} cpu: {reason}")
            if rec_mem is not None:
                ok, reason = safe_to_apply(cur_mem, rec_mem, "memory", args.allow_decrease)
                if ok:
                    desired_mem = rec_mem
                elif args.verbose:
                    eprint(f"skip {wref.namespace}/{wref.kind}/{wref.name}:{cname} mem: {reason}")

            # If the value would not materially change, skip to avoid churn.
            apply_cpu = desired_cpu
            apply_mem = desired_mem
            if apply_cpu is not None and cur_cpu is not None:
                if parse_cpu_millicores(apply_cpu) == parse_cpu_millicores(cur_cpu):
                    apply_cpu = None
            if apply_mem is not None and cur_mem is not None:
                if parse_bytes(apply_mem) == parse_bytes(cur_mem):
                    apply_mem = None

            # Compute desired memory limit from the desired (VPA-derived) request, even if the
            # request itself does not change. This keeps limits in sync with the policy
            # (e.g., request=target but limit=headroom(request)).
            if args.set_memory_limit and desired_mem is not None:
                if args.memory_limit_mode == "equal-request":
                    computed = normalize_memory_quantity_or_none(desired_mem, args.memory_unit)
                else:
                    computed = compute_memory_limit_with_headroom(
                        desired_mem,
                        headroom_of_limit=(args.memory_limit_headroom_percent_of_limit / 100.0),
                        min_headroom_bytes=min_headroom_b,
                        memory_unit=args.memory_unit,
                    )
                if computed is not None:
                    # Default: never decrease memory limits; only raise/add.
                    if lim_mem is not None and not args.allow_decrease_memory_limit:
                        cur_lim_b = parse_bytes(lim_mem)
                        new_lim_b = parse_bytes(computed)
                        if cur_lim_b is not None and new_lim_b is not None and new_lim_b < cur_lim_b:
                            computed = None
                    desired_mem_limit = computed

            # Apply memory limit if it would materially change.
            apply_mem_limit = desired_mem_limit
            if apply_mem_limit is not None and lim_mem is not None:
                if parse_bytes(apply_mem_limit) == parse_bytes(lim_mem):
                    apply_mem_limit = None

            if desired_cpu is None and desired_mem is None and desired_mem_limit is None:
                total_skipped += 1
                continue

            if apply_cpu is None and apply_mem is None and apply_mem_limit is None:
                total_skipped += 1
                continue

            if apply_cpu is not None and lim_cpu is not None:
                exceeds = would_exceed_limit(apply_cpu, lim_cpu, "cpu")
                if exceeds is True and not args.allow_request_above_limit:
                    issues.error(
                        "request_above_limit",
                        f"skip {wref.namespace}/{wref.kind}/{wref.name}:{cname} cpu: "
                        f"request {apply_cpu} would exceed limit {lim_cpu} (use --allow-request-above-limit to override)"
                    )
                    total_skipped += 1
                    continue
                ratio = request_limit_ratio(apply_cpu, lim_cpu, "cpu")
                if ratio is not None and args.warn_request_limit_ratio > 0 and ratio >= args.warn_request_limit_ratio:
                    issues.warn(
                        "request_near_limit",
                        f"warn {wref.namespace}/{wref.kind}/{wref.name}:{cname} cpu: "
                        f"request {apply_cpu} is {ratio:.2f} of limit {lim_cpu}"
                    )
                if exceeds is None and args.verbose:
                    issues.warn(
                        "request_limit_uncomparable",
                        f"warn {wref.namespace}/{wref.kind}/{wref.name}:{cname} cpu: "
                        f"cannot compare request {apply_cpu} to limit {lim_cpu}"
                    )

            if apply_mem is not None:
                limit_after = lim_mem
                if apply_mem_limit is not None:
                    limit_after = apply_mem_limit
                exceeds = None
                if limit_after is not None:
                    exceeds = would_exceed_limit(apply_mem, limit_after, "memory")
                if exceeds is True and not args.allow_request_above_limit:
                    issues.error(
                        "request_above_limit",
                        f"skip {wref.namespace}/{wref.kind}/{wref.name}:{cname} memory: "
                        f"request {apply_mem} would exceed limit {limit_after} (use --allow-request-above-limit to override)"
                    )
                    total_skipped += 1
                    continue
                if limit_after is not None:
                    ratio = request_limit_ratio(apply_mem, limit_after, "memory")
                    if (
                        ratio is not None
                        and args.warn_request_limit_ratio > 0
                        and ratio >= args.warn_request_limit_ratio
                    ):
                        issues.warn(
                            "request_near_limit",
                            f"warn {wref.namespace}/{wref.kind}/{wref.name}:{cname} memory: "
                            f"request {apply_mem} is {ratio:.2f} of limit {limit_after}"
                        )
                if exceeds is None and args.verbose:
                    issues.warn(
                        "request_limit_uncomparable",
                        f"warn {wref.namespace}/{wref.kind}/{wref.name}:{cname} memory: "
                        f"cannot compare request {apply_mem} to limit {limit_after}"
                    )

            cobj = containers[idx]
            has_resources = isinstance(cobj.get("resources"), dict)
            has_requests = has_resources and isinstance((cobj.get("resources") or {}).get("requests"), dict)
            has_limits = has_resources and isinstance((cobj.get("resources") or {}).get("limits"), dict)
            reqs_obj = (cobj.get("resources") or {}).get("requests") if has_requests else {}
            lims_obj = (cobj.get("resources") or {}).get("limits") if has_limits else {}
            has_cpu = has_requests and isinstance(reqs_obj, dict) and "cpu" in reqs_obj
            has_memory = has_requests and isinstance(reqs_obj, dict) and "memory" in reqs_obj
            has_memory_limit = has_limits and isinstance(lims_obj, dict) and "memory" in lims_obj

            # Track deltas for multi-change headroom checks/summaries.
            if apply_cpu is not None:
                new_cpu_m = parse_cpu_millicores(apply_cpu) or 0
                old_cpu_m = parse_cpu_millicores(cur_cpu or "") or 0
                cpu_delta_m += new_cpu_m - old_cpu_m
            if apply_mem is not None:
                new_mem_b = parse_bytes(apply_mem) or 0
                old_mem_b = parse_bytes(cur_mem or "") or 0
                mem_delta_b += new_mem_b - old_mem_b
            container_changes += 1

            patch_ops = build_json_patch_for_container_resources(
                wref.kind,
                idx,
                apply_cpu,
                apply_mem,
                apply_mem_limit,
                has_resources=has_resources,
                has_requests=has_requests,
                has_limits=has_limits,
                has_cpu=has_cpu,
                has_memory=has_memory,
                has_memory_limit=has_memory_limit,
            )
            ops.extend(patch_ops)
            any_change = True

            backport_cpu = apply_cpu
            backport_mem = apply_mem
            backport_mem_limit = apply_mem_limit
            if args.backport_gitops and args.backport_include_unchanged:
                if desired_cpu is not None:
                    backport_cpu = desired_cpu
                if desired_mem is not None:
                    backport_mem = desired_mem
                if desired_mem_limit is not None:
                    backport_mem_limit = desired_mem_limit

            if backport_cpu is not None or backport_mem is not None or backport_mem_limit is not None:
                entry = backport_resources.setdefault(wref, {}).setdefault(cname, {})
                if backport_cpu is not None or backport_mem is not None:
                    req = entry.setdefault("requests", {})
                    if backport_cpu is not None:
                        req["cpu"] = backport_cpu
                    if backport_mem is not None:
                        req["memory"] = backport_mem
                if backport_mem_limit is not None:
                    lim = entry.setdefault("limits", {})
                    lim["memory"] = backport_mem_limit

            if args.verbose or (not args.apply and not args.summary_only):
                eprint(
                    f"{'apply' if args.apply else 'plan'} {wref.namespace}/{wref.kind}/{wref.name}:{cname} "
                    f"cpu {cur_cpu or '-'} -> {apply_cpu or '-'}; mem {cur_mem or '-'} -> {apply_mem or '-'}; "
                    f"memLimit {lim_mem or '-'} -> {apply_mem_limit or '-'}"
                )

        if not any_change:
            continue

        pod_cpu_m_after = pod_cpu_m_before + cpu_delta_m
        pod_mem_b_after = pod_mem_b_before + mem_delta_b

        # Safety check: ensure the *pod-level* sum of requests fits on at least one node.
        if check_fit_on_node and capacity is not None:
            if pod_cpu_m_after > capacity.max_node_cpu_m or pod_mem_b_after > capacity.max_node_mem_bytes:
                issues.error(
                    "pod_would_not_fit_on_any_node",
                    f"skip {wref.namespace}/{wref.kind}/{wref.name}: "
                    "pod request would not fit on any node "
                    f"(cpu {pod_cpu_m_after}m > max-node {capacity.max_node_cpu_m}m or "
                    f"mem {pod_mem_b_after}B > max-node {capacity.max_node_mem_bytes}B). "
                    "Re-run with --no-check-fit-on-node to override."
                )
                total_skipped += 1
                continue

        planned_stats[wref] = {
            "cpu_delta_m": cpu_delta_m,
            "mem_delta_bytes": mem_delta_b,
            "pod_cpu_m_after": pod_cpu_m_after,
            "pod_mem_bytes_after": pod_mem_b_after,
            "container_changes": container_changes,
        }
        planned_patches.append((wref, ops))

        total_patched += 1

        if not args.apply and not args.summary_only:
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

    # Final multi-change headroom check (based on what we actually planned to change).
    plan_totals = summarize_plan(planned_stats)
    if check_cluster_headroom:
        if plan_totals.cpu_delta_m > capacity.headroom_cpu_m or plan_totals.mem_delta_bytes > capacity.headroom_mem_bytes:
            eprint(
                "refusing to apply: planned net request increase exceeds cluster headroom "
                f"(cpu +{plan_totals.cpu_delta_m}m vs headroom {capacity.headroom_cpu_m}m; "
                f"mem +{plan_totals.mem_delta_bytes}B vs headroom {capacity.headroom_mem_bytes}B). "
                "Re-run with --no-check-cluster-headroom to override."
            )
            issues.print_summary()
            return 1

    eprint(
        "plan summary:\n"
        f"- workloads touched: {plan_totals.workloads}\n"
        f"- container changes: {plan_totals.container_changes}\n"
        f"- delta requests: cpu {format_cpu_human(plan_totals.cpu_delta_m)}, mem {format_bytes_human(plan_totals.mem_delta_bytes)}\n"
        f"- projected cluster requests (sum pod requests):\n"
        f"  - cpu {format_cpu_human(capacity.req_cpu_m + plan_totals.cpu_delta_m)} / {format_cpu_human(capacity.alloc_cpu_m)} ({format_ratio(capacity.req_cpu_m + plan_totals.cpu_delta_m, capacity.alloc_cpu_m)} of allocatable)\n"
        f"  - mem {format_bytes_human(capacity.req_mem_bytes + plan_totals.mem_delta_bytes)} / {format_bytes_human(capacity.alloc_mem_bytes)} ({format_ratio(capacity.req_mem_bytes + plan_totals.mem_delta_bytes, capacity.alloc_mem_bytes)} of allocatable)\n"
        f"- cluster headroom (allocatable - requested):\n"
        f"  - cpu {format_cpu_human(capacity.headroom_cpu_m)}\n"
        f"  - mem {format_bytes_human(capacity.headroom_mem_bytes)}\n"
        f"- max pod requests after (for changed workloads):\n"
        f"  - cpu {format_cpu_human(plan_totals.max_pod_cpu_m_after)} (max node allocatable {format_cpu_human(capacity.max_node_cpu_m)})\n"
        f"  - mem {format_bytes_human(plan_totals.max_pod_mem_bytes_after)} (max node allocatable {format_bytes_human(capacity.max_node_mem_bytes)})"
    )

    patched_refs: List[WorkloadRef] = []
    if args.apply:
        for wref, ops in planned_patches:
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
                    issues=issues,
                )
                patched_refs.append(wref)
            except subprocess.CalledProcessError as ex:
                eprint(f"failed to patch {wref.namespace}/{wref.kind}/{wref.name}: {ex}")
                if getattr(ex, "stderr", None):
                    eprint(str(ex.stderr).strip())
                return 1

    if args.backport_gitops and backport_resources:
        rollout_failures: List[str] = []
        if args.apply and not args.no_rollout_wait:
            for wref in patched_refs:
                if wref.kind not in ("Deployment", "StatefulSet", "DaemonSet"):
                    issues.warn(
                        "rollout_status_skipped",
                        f"skip rollout status for {wref.namespace}/{wref.kind}/{wref.name}: unsupported kind",
                    )
                    continue
                try:
                    run_kubectl(
                        [
                            "rollout",
                            "status",
                            f"{workload_resource(wref.kind)}/{wref.name}",
                            "-n",
                            wref.namespace,
                            "--timeout",
                            args.rollout_timeout,
                        ],
                        args.kubeconfig,
                        issues=issues,
                    )
                except subprocess.CalledProcessError as ex:
                    msg = f"{wref.namespace}/{wref.kind}/{wref.name}"
                    rollout_failures.append(msg)
                    issues.error("rollout_failed", f"rollout status failed for {msg}: {ex}")

        if rollout_failures:
            eprint(
                "warning: some rollouts did not report success; backporting now may lock in a bad spec:\n"
                + "\n".join(f"- {x}" for x in rollout_failures)
            )

        if not prompt_confirm("Backport these resource changes into the local GitOps repo?", assume_yes=args.yes):
            eprint("skipping GitOps backport (no confirmation).")
        else:
            try:
                repo_root = git_repo_root()
            except RuntimeError as ex:
                issues.error("backport_repo_root", str(ex))
                issues.print_summary()
                return 1

            gitops_root = resolve_gitops_root(repo_root, args.gitops_root)
            if not os.path.isdir(gitops_root):
                issues.error("backport_gitops_root", f"gitops root not found: {gitops_root}")
                issues.print_summary()
                return 1

            try:
                src_paths = get_argocd_source_paths_by_workload(
                    args.kubeconfig, argocd_namespace=args.argocd_namespace, issues=issues
                )
            except subprocess.CalledProcessError as ex:
                issues.error(
                    "backport_argocd_apps",
                    f"failed to list Argo Applications in namespace {args.argocd_namespace}: {ex}",
                )
                issues.print_summary()
                return 1

            patch_files_written = 0
            kustomizations_updated = 0
            backported_workloads = 0
            backport_skipped = 0

            for wref, per_container in sorted(
                backport_resources.items(), key=lambda x: (x[0].namespace, x[0].kind, x[0].name)
            ):
                app_path = src_paths.get(wref)
                if not app_path:
                    issues.warn(
                        "backport_no_app_mapping",
                        f"skip backport {wref.namespace}/{wref.kind}/{wref.name}: not found in Argo Application status",
                    )
                    backport_skipped += 1
                    continue

                app_dir = resolve_gitops_app_dir(repo_root, gitops_root, app_path)
                if not app_dir:
                    issues.error(
                        "backport_app_path_missing",
                        f"skip backport {wref.namespace}/{wref.kind}/{wref.name}: cannot resolve app path {app_path}",
                    )
                    backport_skipped += 1
                    continue

                kustomization_path = os.path.join(app_dir, "kustomization.yaml")
                if not os.path.isfile(kustomization_path):
                    issues.error(
                        "backport_not_kustomize",
                        f"skip backport {wref.namespace}/{wref.kind}/{wref.name}: no kustomization.yaml at {app_dir}",
                    )
                    backport_skipped += 1
                    continue

                safe_kind = re.sub(r"[^A-Za-z0-9_.-]+", "-", wref.kind).lower()
                safe_name = re.sub(r"[^A-Za-z0-9_.-]+", "-", wref.name)
                patch_filename = f"patch-vpa-requests-{safe_kind}-{safe_name}.yaml"
                patch_path = os.path.join(app_dir, patch_filename)
                patch_yaml = render_vpa_requests_patch_yaml(wref, per_container)

                prev = None
                if os.path.isfile(patch_path):
                    with open(patch_path, "r", encoding="utf-8") as f:
                        prev = f.read()

                if prev != patch_yaml:
                    with open(patch_path, "w", encoding="utf-8") as f:
                        f.write(patch_yaml)
                    patch_files_written += 1

                if kustomization_add_patch(kustomization_path, patch_filename):
                    kustomizations_updated += 1

                backported_workloads += 1

            eprint(
                "gitops backport summary:\n"
                f"- backported workloads: {backported_workloads}\n"
                f"- patch files written/updated: {patch_files_written}\n"
                f"- kustomizations updated: {kustomizations_updated}\n"
                f"- skipped: {backport_skipped}\n"
                f"- gitops root: {gitops_root}"
            )

    issues.print_summary()
    eprint(f"patched_workloads={total_patched} skipped_items={total_skipped} mode={'apply' if args.apply else 'dry-run'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
