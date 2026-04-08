# Valkey Shared Library (`data/valkey/base`)

# Introduction

This component provides a **Bespoke High-Availability Valkey Cluster** (fork of Redis) using standard Kubernetes primitives (StatefulSets) and Sentinel for failover coordination.

It is designed as a **Shared Library**. It does not run on its own but is consumed by overlays (or directly by apps) that provide the necessary configuration (Secrets, Namespaces).

For open/resolved issues, see [docs/component-issues/valkey.md](../../../../../docs/component-issues/valkey.md).

---

## Architecture

```mermaid
flowchart TB
    APP[Client App]
    SVC_RW[Service: valkey]
    SENTINEL[StatefulSet: valkey-sentinel<br/>(3 Replicas)]
    VALKEY[StatefulSet: valkey<br/>(3 Replicas)]
    PVC[PVC: data]

    APP -->|Read/Write| SVC_RW
    SVC_RW -->|Routes| VALKEY
    SENTINEL -->|Monitors| VALKEY
    VALKEY -->|Persists| PVC
```

- **Topology**:
    - **Data Nodes**: 3 replicas (`valkey`).
    - **Sentinels**: 3 replicas (`valkey-sentinel`) monitoring the data nodes.
- **Failover**: Sentinels detect primary failure and coordinate failover. The `valkey-entrypoint.sh` script handles initial replication setup.
- **Discovery**: Headless services (`valkey-headless`, `valkey-sentinel-headless`) allow peer discovery.

---

## Subfolders

- **None**: This is a flat library.

---

## Container Images / Artefacts

| Artefact | Version | Source |
|----------|---------|--------|
| Valkey | `9.0.0-alpine` | `valkey/valkey` |

---

## Dependencies

| Dependency | Purpose |
|------------|---------|
| `storage/shared` | Requires `shared-rwo` StorageClass. |
| `secrets` | Requires a Secret named `valkey-auth` with a `password` key. |

---

## Communications With Other Services

### Kubernetes Service → Service Calls

- **Client → Valkey**: Connection to `valkey` Service on port 6379.
- **Sentinel → Valkey**: Monitoring on port 6379.
- **Sentinel → Sentinel**: Coordination on port 26379.

### Mesh-level Concerns

- **Mismatched Ports**: Note that pure Redis protocols sometimes have issues with Envoy if not strictly configured.
- **Headless Services**: Heavily relied upon for peer discovery.
- **Read-after-write correctness**: the `valkey` Service load-balances across all pods. For strict read-after-write behavior, clients (and smoke tests) should discover the current master via Sentinel and connect to it directly.

---

## Initialization / Hydration

- **Scripts**: Relies on `valkey-entrypoint.sh` and `sentinel-entrypoint.sh` (mounted from ConfigMap) to generate configuration files at runtime.
- **Bootstrapping**: The first node (`valkey-0`) assumes primary role; others become replicas.

---

## Argo CD / Sync Order

| Application | Sync Wave | Notes |
|-------------|-----------|-------|
| `data-valkey` | `0` | Standard wave. |

---

## Operations (Toils, Runbooks)

### Manual Failover
Connect to a Sentinel and force failover:
```bash
kubectl exec -it valkey-sentinel-0 -- valkey-cli -p 26379 SENTINEL failover valkey
```

### Resetting Replication
If state gets corrupted, scaling down to 0 and back up (or deleting PVCs) may be required, but usually Sentinel heals the topology.

---

## Customisation Knobs

- **Env Vars**: `VALKEY_PASSWORD` (from Secret).
- **Resources**: Editable via Kustomize patches on StatefulSets.

---

## Oddities / Quirks

- **Bespoke Scripts**: The logic for "who is master" is partly in the bash entrypoint and mainly managed by Sentinel after startup.
- **Permissions**: The entrypoint forces writes to `/valkey/data` to avoid permission issues with the default image paths.

---

## TLS, Access & Credentials

| Concern | Details |
|---------|---------|
| TLS | **None**: Traffic is plaintext inside the pod (Mesh mTLS protects the wire). |
| Access | **NetworkPolicies**: Restricts ingress to namespaces with `darksite.cloud/valkey-client=true`. |
| Credentials | **Password**: Provided via `valkey-auth` Secret. |

---

## Dev → Prod

Same architecture. Differences would be in resource sizing via overlays.

---

## Smoke Jobs / Test Coverage

- **Plan**: Smoke depends on the consumer. Prefer a Sentinel-aware smoke that targets the current master (see `platform/gitops/components/platform/forgejo/valkey` for an example).

```bash
kubectl run smoke-valkey --rm -it --image=valkey/valkey:9.0.0-alpine --restart=Never -- valkey-cli -h valkey -a <PASSWORD> PING
```

---

## HA Posture

- **Redundancy**: 3 data nodes + 3 Sentinels.
- **Failover**: Sentinel-orchestrated. If primary fails, Sentinels elect a new primary and reconfigure replicas.
- **Client Awareness**: Clients must be Sentinel-aware (connecting to Sentinels to ask for current primary) OR rely on the `valkey` Service (which might lag during failover if it points to all pods).

---

## Security

- **NetworkPolicies**: Strict ingress allowing only `darksite.cloud/valkey-client=true` labeled namespaces.
- **Context**: `runAsNonRoot: true`, `capabilities.drop: [ALL]`.
- **Auth**: Password protected (AUTH command).

---

## Backup and Restore

- **By design (cache-only)**: No backup/restore mechanism is shipped for Valkey in this repo.
- **PVCs**: The PVCs are for restart smoothing and operational convenience, not as a DR guarantee.
- **Contract**: Losing Valkey data must be acceptable to consumers (derived data only).
  - See `docs/design/data-services-patterns.md` and `docs/component-issues/valkey.md`.
