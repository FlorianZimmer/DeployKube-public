# Design: Multi-Node HA Storage (Ceph-backed: PVC + S3 + blast-radius controls)

Last updated: 2026-01-09  
Status: Design (not implemented)

## Tracking

- Canonical tracker: `docs/component-issues/storage-multi-node-ha.md`

Related docs (inputs / constraints):
- Storage contract + single-node profile: `docs/design/storage-single-node.md`
- Multitenancy storage reachability model: `docs/design/multitenancy-storage.md`
- Standard profile NFS backend (today): `docs/design/out-of-cluster-nfs.md`
- DR / backup doctrine: `docs/design/disaster-recovery-and-backups.md`, `docs/guides/backups-and-dr.md`
- Repo-truth versions/components: `target-stack.md`

This design describes the **intended multi-node HA storage profile** for DeployKube, centered around **Ceph**:
- PVC backends: Ceph **RBD** (`shared-rwo`) and (optionally) CephFS (`shared-rwx`)
- Object storage: Ceph **RGW** (S3 contract; replaces Garage for HA profiles)

It is written to:
- keep workload contracts stable (`shared-rwo` / S3 env vars),
- reduce storage blast radius via explicit reachability controls,
- define upgrade/rollback and restore drills before we ship the implementation.

Non-goal: claim any live cluster state.

---

## 1) Problem statement

Storage is a major blast radius:
- A default StorageClass change can redirect “all new PVCs” to a different backend.
- Backend reachability can let tenants bypass Kubernetes scoping (talking directly to NFS/backup endpoints today, and to Ceph services tomorrow).
- Without an explicit upgrade/rollback and restore plan, “storage as a platform primitive” becomes un-operable.

The current repo reality:
- `shared-rwo` is the stable workload contract and default StorageClass (`target-stack.md`).
- Standard profiles use out-of-cluster NFS (`docs/design/out-of-cluster-nfs.md`).
- Single-node profiles use node-local `local-path-provisioner` for `shared-rwo` (`docs/design/storage-single-node.md`).
- Garage provides S3 today but is single-node and intentionally non-HA (`platform/gitops/components/storage/garage/README.md`).

Multi-node / HA requires:
- an HA PVC backend (RBD),
- an HA S3 backend (RGW),
- and explicit reachability/policy to prevent “backend bypass”.

---

## 2) Goals

1. Provide a multi-node HA storage profile that supports:
   - `shared-rwo` (default) with predictable RWO semantics (Ceph RBD).
   - HA S3 endpoint with the existing S3 env var contract (Ceph RGW).
2. Keep workload-facing contracts stable:
   - StorageClass names (`shared-rwo`, `shared-rwx` when shipped).
   - S3 environment variables and bucket naming contract.
3. Reduce blast radius:
   - one-default-StorageClass posture is explicit and verified,
   - backend reachability model is documented and enforced where possible.
4. Define upgrade/rollback + restore drills up-front so implementation can ship with evidence.

---

## 3) Non-goals (for this design PR)

- Implementing Ceph in-repo (GitOps components, charts, node prep).
- Promising hard multi-customer isolation in a shared cluster (Tier S is still logical isolation).
- Zero-downtime, in-place migration of existing PVCs between backends.

---

## 4) Stable workload contracts (must not change)

### 4.1 PVC StorageClass contract

Stable names:
- `shared-rwo` (default): the platform “standard” RWO class.
- `shared-rwx` (optional, only when explicitly shipped): shared filesystem semantics.

Backend mapping by profile (intended):
- Standard profiles (today): `shared-rwo` → NFS provisioner.
- Single-node profile (today): `shared-rwo` → local-path provisioner.
- Multi-node HA profile (planned): `shared-rwo` → Ceph RBD CSI; `shared-rwx` → CephFS CSI (only when shipped).

### 4.2 S3 contract

Workloads keep using the S3 env var contract (same as Garage today):
- `S3_ENDPOINT`, `S3_REGION`
- `S3_ACCESS_KEY`, `S3_SECRET_KEY`
- bucket variables (`BUCKET_*` or workload-specific bucket names)

Multi-node HA profile replaces “Garage S3” with “Ceph RGW S3” without rewriting workloads.

---

## 5) Proposed backend: Ceph (RBD + RGW, CephFS later)

### 5.1 Deployment choice (in-cluster vs external)

We intentionally defer the final choice until we validate Talos/Proxmox operational constraints, but we lock the *interface* contract now.

Two viable implementation shapes:

**Option A — In-cluster Ceph via Rook (preferred long-term if Talos constraints allow)**
- Pros: self-contained, GitOps-managed, portable across environments.
- Cons: privileged node access and OSD device management are operationally sensitive (especially on Talos).

**Option B — External Ceph (Proxmox-managed) + in-cluster CSI/RGW wiring**
- Pros: separates “storage cluster ops” from Kubernetes; may align with Proxmox ecosystems.
- Cons: more off-cluster reachability surface; requires explicit network segmentation and credentials custody.

Design decision for v1 multi-node HA profile:
- Default intent: **RBD + RGW** first (covers `shared-rwo` + S3).
- Add CephFS only when we explicitly ship `shared-rwx` and have concrete workloads requiring RWX.

#### 5.1.1 Decision gates (Rook vs external Ceph)

We defer the final “Rook in-cluster vs external Ceph” choice, but we do not defer what evidence decides it.

Decision gates (minimum evidence):

1. **Talos / device management feasibility**
   - Can we reliably present dedicated OSD devices to the Kubernetes nodes (Proxmox passthrough / virtio disks) with stable identifiers?
   - Can we handle disk replacement without ad-hoc node surgery?

2. **Operational control loop fit**
   - Rook: can we operate required privileged DaemonSets on Talos (OSD prepare, CSI, monitors) with the expected security posture?
   - External: can we keep the Ceph management plane out-of-cluster while still delivering a clean in-cluster CSI/RGW contract (credentials custody, network segmentation)?

3. **Failure domain reality**
   - Do we have ≥3 independent failure domains (hosts) to make “HA” meaningful?
   - If we are still on a single hypervisor, Ceph may be a *feature* (consistent contract) but not true HA.

4. **Upgrade/rollback constraints**
   - Can we pin and upgrade the chosen shape with an evidence-backed runbook?
   - Can we recover from an upgrade failure via “rebuild + restore” drills without hand-editing live state?

Outcome guidance:
- If Talos/privileged constraints are a blocker, prefer **external Ceph** for v1 and keep the in-cluster shape as the long-term goal.
- If external networking/credentials custody becomes the bigger risk surface, prefer **Rook in-cluster** once Talos constraints are solved.

#### 5.1.2 Minimum sizing / failure-domain assumptions

Ceph HA requires explicit minimums; otherwise we create a “looks HA but isn’t” trap.

Minimum assumptions for a “real HA” profile:
- **3 failure domains** (hosts) minimum.
- **Replication**: plan for `size=3` and `min_size=2` (RBD pools) unless we explicitly document a smaller development posture.
- **OSDs**: at least one dedicated OSD per failure domain (and enough total capacity headroom for backfill).

Non-HA “transition” posture (allowed only with explicit labeling):
- Running Ceph across multiple Kubernetes nodes on the **same hypervisor** is still a single failure domain; treat it as “contract stabilization”, not HA.

### 5.2 StorageClass posture (Ceph profile)

`shared-rwo` (Ceph RBD):
- Default StorageClass: **yes** (and must be the *only* default).
- `volumeBindingMode`: prefer `WaitForFirstConsumer` for multi-node scheduling correctness (avoid provisioning a PV tied to a node before a pod schedules).
- `reclaimPolicy`: default **Retain** for platform workloads (aligns with current contract).

`shared-rwx` (CephFS; optional):
- Not default.
- Only shipped when explicitly enabled and guarded (see multitenancy storage restrictions).

### 5.3 S3 endpoint posture (Ceph RGW)

RGW should be treated like a platform service:
- ingress via the standard Gateway (TLS terminated consistently),
- NetworkPolicy allowlist for callers,
- credentials only via Vault/ESO,
- smokes for S3 semantics and tail latency.

---

## 6) Threat model + backend reachability model (blast-radius hardening)

This is the “storage is a blast radius” core: do not rely on “people will not talk to backend IPs”.

### 6.0 Storage threat model mapping (S1–S4 → Ceph surfaces)

This applies the storage threat model from `docs/design/multitenancy-storage.md` to Ceph/RGW/CSI so future hardening is grounded and testable.

| Tier | Ceph surface | Primary risk | Required guardrails (examples) |
|------|--------------|--------------|--------------------------------|
| S1 | RBD/CephFS PVC data path | accidental data loss / operator mistakes | explicit default StorageClass posture; clear reclaim/retention; restore drills |
| S2 | Backend reachability (MON/MGR/RGW/CSI endpoints) | tenant bypasses Kubernetes and talks to backends directly | tenant “no `ipBlock`” NetPol guardrail; Ceph namespace default-deny + allowlists |
| S3 | Control plane mutation (Ceph CRDs/CSI config/Secrets) | tenant or mis-scoped automation changes storage control plane | Argo AppProject allow/deny; RBAC deny; admission guardrails for access-plane objects |
| S4 | Credential/secret exfiltration (RGW admin creds, CSI creds) | tenant materializes platform storage credentials via secret projection | platform-owned secret projection only; deny tenant `ExternalSecret`; Vault custody + scoped roles |

### 6.1 Shared cluster (Tier S) reachability invariants

From `docs/design/multitenancy-storage.md`:
- Tenants must not be able to reach backend endpoints directly (S2: backend reachability bypass).
- Tenants must not be able to author arbitrary `NetworkPolicy` exceptions (GitOps-managed only; Kyverno validation where possible).

For Ceph-backed HA storage, “backend endpoints” includes:
- Ceph MON/MGR services (control plane),
- RBD/CephFS CSI endpoints,
- RGW admin endpoints,
- and (if external) any off-cluster Ceph/RGW IPs.

### 6.2 In-cluster Ceph reachability controls (planned implementation)

When Ceph runs in-cluster (e.g. `rook-ceph` namespace):
- Apply NetworkPolicies in `rook-ceph` to:
  - allow required intra-ceph traffic within the namespace,
  - allow CSI pods (their namespaces) to reach Ceph services,
  - allow RGW ingress only from allowed namespaces (observability, backup-system, platform namespaces),
  - deny everything else by default.
- Keep RGW *user-facing* access through the gateway only (no direct ClusterIP access from tenant namespaces).

### 6.3 External Ceph reachability controls (if Option B)

If Ceph is external:
- Treat the external Ceph network as “backend IPs” and block tenant egress to it.
- Enforce “no `ipBlock`” for tenant NetworkPolicies (Kyverno validate), so a tenant cannot open direct egress to backend subnets.
- If the platform needs to reach external Ceph, route via platform-owned namespaces only.

---

## 7) Upgrade and rollback (must be evidence-backed)

### 7.1 Upgrade principles

- Pin versions (operator + CSI + RGW) in repo-truth and GitOps manifests.
- Upgrade one dimension at a time (operator first, then Ceph version if applicable).
- Gate upgrades with smokes:
  - PVC provisioning + mount test on `shared-rwo`.
  - S3 API + tail latency smoke against RGW.

### 7.2 Rollback posture

Rollback is constrained:
- “Rollback” of Ceph versions may be impossible or unsafe across certain upgrade steps.
- Treat rollback as “roll forward” where possible; treat “restore from backups” as the hard escape hatch.

Minimum rollback guarantee to aim for in implementation:
- If an upgrade breaks the storage surface, operators can:
  - stop non-essential workloads (reduce write load),
  - restore tier-0 services from off-cluster backups,
  - rebootstrap the cluster and reattach/restore data (rebuild + restore model).

---

## 8) Backup and restore drills (required before declaring HA profile “ready”)

This design aligns with the “rebuild + restore” model from `docs/design/storage-single-node.md`.

### 8.1 Tier-0 restore drill (must exist)

For a Ceph-backed HA profile, a minimum drill should prove:
1. Fresh bootstrap + GitOps reconcile to a functioning control plane.
2. Restore Vault (raft snapshot restore) and verify `sealed=false`.
3. Restore Postgres logical dumps for platform DBs (Keycloak/Forgejo/PowerDNS).
4. Restore object-store-dependent data (if any) or prove it is reconstructible.

Evidence requirements:
- commands + success excerpts in `docs/evidence/YYYY-MM-DD-*.md`,
- Argo `Synced/Healthy` for storage + tier-0 apps,
- smoke jobs succeed after restore.

### 8.2 “Data plane sanity” smokes (must exist)

PVC:
- a validation job provisions a PVC on `shared-rwo`, writes, reads, and cleans up (and does not leak PVs).

S3:
- an S3 semantics smoke (HEAD/GET/PUT/LIST) and a tail-latency smoke (p50/p95/p99/max) similar to the Garage job.

---

## 9) Migration story (how this becomes default)

We do not support in-place backend swaps of existing PVs.

Supported migration model:
- Stand up a **new** deployment using the Ceph-backed profile.
- Use backup/restore to migrate state (“rebuild + restore”).
- Keep workload manifests unchanged (contracts stay stable).

Promotion doctrine:
- Implement in dev first, then ship to prod with evidence and explicit promotion notes.

---

## 10) Implementation outline (future GitOps work)

This section is intentionally high-level. The implementation PR(s) should create:
- `platform/gitops/components/storage/ceph/` (or `rook-ceph/`) with pinned versions, HA posture, and NetworkPolicy.
- `platform/gitops/components/storage/rgw/` (or combined with Ceph component) with gateway exposure and smokes.
- `StorageClass/shared-rwo` backed by Ceph RBD CSI in the HA profile.
- Optional: `StorageClass/shared-rwx` backed by CephFS when explicitly enabled.

Each implementation PR must include:
- component README(s),
- validation job(s) per `docs/design/validation-jobs-doctrine.md`,
- evidence files for dev and prod.
