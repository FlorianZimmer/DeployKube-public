# Data Services Patterns (Valkey & CloudNativePG)

This note records the reusable scaffolding we ship in `platform/gitops/components/data/` so future workloads can adopt the same primitives without copy/paste.

## Tracking

- Canonical tracker: `docs/component-issues/data-services-patterns.md`

## Pattern vs component boundaries

DeployKube treats “data services” as a mix of **shared libraries** and **workload-owned components**:

### Shared libraries (`platform/gitops/components/data/**/base`)

The `base` directories are reusable building blocks and must stay **consumer-friendly**:

- No consumer-specific names (`forgejo-*`, `powerdns-*`, …).
- Avoid `Namespace` resources (consumers provide `namespace:` and `namePrefix:` in their Kustomize layer).
- No secrets material:
  - no plaintext credentials,
  - no `ExternalSecret` objects (consumers own Vault paths and key custody).
- Keep default-deny NetworkPolicies **out of the base** unless the required network flows are proven stable across all consumers.

### Workload-owned components (`platform/gitops/components/**/<workload>/{postgres,valkey}`)

Each workload that adopts a data service must own the “edges”:

- Secret wiring: `ExternalSecret` objects and documented Vault paths.
- Naming/patches: cluster name, storage sizing, resource limits.
- Security posture: **ingress-restricting NetworkPolicies** for the specific caller set.
- Verification: `tests/` and/or `smoke-tests/` bundles (Argo-owned) per `docs/design/validation-jobs-doctrine.md`.
- Any schema init / migration / cutover Jobs that are specific to the workload.

## Valkey Pattern
- **Base component**: `platform/gitops/components/data/valkey/base` owns the namespace, ServiceAccount, scripts, StatefulSets (primaries + sentinels), Services, PDBs, and NetworkPolicies. It mounts a PVC at `/valkey` and ensures the runtime config writes RDB/AOF data under `/valkey/data` to avoid the permission failures we hit on Nov 9, 2025 when Valkey defaulted to the container filesystem.
- **Secrets**: every consumer must supply a `valkey-auth` Secret via ExternalSecrets. Point the `secretStoreRef` at `vault-core` so the password comes from Vault, and document the Vault path (e.g., `secret/data/<component>/redis`).
- **Durability contract (default)**: Valkey is treated as a **cache-only** primitive in this repo:
  - no backup/restore mechanism is shipped for Valkey,
  - losing Valkey data must be acceptable to consumers (sessions/queues/caches must be recoverable by higher-level systems),
  - PVCs exist for restart smoothing and operational convenience, not as a DR guarantee.
  If you need a stateful key-value store with backup/restore semantics, treat that as a separate tracked workstream (operator-based or alternate technology).
- **Overlay steps**:
  1. Create `components/<domain>/<component>/valkey/` with a `kustomization.yaml` that pulls in the base, namespace labels, and any StorageClass/size patches.
  2. Generate the ExternalSecret manifest referencing the Vault key for that component.
  3. Add patches for env overrides (`VALKEY_SERVICE_NAME`, sentinel cluster name) if the defaults conflict.
  4. Register an Argo Application under `apps/base/` so the overlay syncs automatically.
- **Jobs**: pair every Valkey adoption with a `forgejo`-style cache switch job (`components/platform/forgejo/jobs/cache-switch.sh`) so workloads flip from LevelDB/memory stores to Sentinel endpoints safely.

## CloudNativePG Pattern
- **Operator**: `components/data/postgres/cnpg-operator` installs the CNPG Helm chart. The canonical pinned chart/app versions live with the component (`components/data/postgres/cnpg-operator/README.md`, `manifest.yaml`) and are summarized in `target-stack.md`; this design doc describes the pattern and should not duplicate the live pin. Always refresh the chart via `helm template` before bumping versions; the vendored CRDs need `argocd.argoproj.io/sync-options: Replace=true`, and the Argo `Application/data-postgres-operator` sets `ServerSideApply=true` to keep the CRD apply path under size limits.
- **Platform API wrapper (implemented baseline)**: new internal consumers should prefer `data.darksite.cloud/v1alpha1` (`PostgresClass`, `PostgresInstance`) over direct `postgresql.cnpg.io` usage. The CRDs live under `components/platform/apis/data/data.darksite.cloud/crd`, the class catalog under `components/platform/apis/data/data.darksite.cloud/classes`, and the controller under `components/platform/apis/data/data.darksite.cloud/controller`. Keycloak, Forgejo, PowerDNS, and Harbor are already migrated internal consumers, and the disposable `platform-poc-disposable` class now covers PoC/lab consumers like IDLab. The controller defaults helper resource names per instance, supports alias Services plus backup TLS wiring, allows optional WAL omission for disposable classes, and permits explicit legacy-name overrides where cutovers need to preserve live PVC/CronJob/service contracts.
- **Legacy base overlay**: `components/data/postgres/base` remains only as a historical cutover aid. New platform-owned consumers should declare `PostgresInstance` instead of importing raw CNPG base manifests directly.
- **Secrets**: every overlay consumes Vault (`secret/data/<component>/database`) through ExternalSecrets. Forgejo taught us to pre-create those keys; otherwise CNPG fails with `secret... not found` during bootstrap.
- **Migration jobs**: replicate the Forgejo approach—seed data via a one-shot job, then switch config in another job, both using `deploykube/bootstrap-tools:1.4` so runtime parity holds.

  The `deploykube/bootstrap-tools:1.4` image is built during Stage 0 (`shared/scripts/build-bootstrap-tools-image.sh`) and contains every tool the Jobs need. Adjust `shared/images/bootstrap-tools/Dockerfile` when new utilities are required and rerun Stage 0 so the updated binaries are available to future jobs.

### Postgres NetworkPolicy posture

Postgres is a “high blast radius” service: by default, every CNPG cluster should ship with an **explicit ingress allow-list** in the workload component (not in the shared base).

Baseline expectations per Postgres cluster overlay or `PostgresInstance` backend:

- Restrict Postgres client traffic (`TCP/5432`) to the intended caller set (often “same namespace only”; prefer tighter selectors if feasible).
- Allow CNPG operator → instance status traffic (`TCP/8000`) from `cnpg-system`.
  - CNPG uses the instance status endpoint for reconciliation and readiness.
- Allow monitoring → metrics traffic (`TCP/9187`) from the `monitoring` namespace (if metrics are enabled).

Avoid default-deny **egress** NetworkPolicies for CNPG instances unless you have a proven allow-list:

- We hit real outages when egress rules blocked `kubernetes.default.svc:443` during bootstrap/reconcile.
- Start with ingress restriction + DB auth, then add egress controls only when the required control-plane flows are fully mapped and tested.

### Service mesh scope (Istio) for data services

Istio is not “only for external traffic”; it’s also a strong default for **workload-to-workload** traffic (mTLS, policy, telemetry). However, operators/controllers and stateful data planes are special:

- **Default**: application workloads run **in-mesh**. Operators/controllers (e.g. CNPG operator) are generally treated as **out-of-mesh** unless we explicitly wire and test them for mesh mTLS.
- **Stateful stores are case-by-case**:
  - CNPG/Postgres: **out-of-mesh by default** in this repo (see next bullet).
  - Valkey: can be **in-mesh** (and is treated as such by its library docs), but pure TCP/headless patterns may require additional Istio tuning.
- **CNPG gotcha**: if CNPG instance pods are injected but the operator isn’t, STRICT mTLS can break operator ↔ instance communication and anything that depends on that (status extraction, backups, failover logic). In this repo, CNPG instance pods are kept out-of-mesh by default unless we intentionally move CNPG into the mesh as a whole.
- **When a DB is out-of-mesh** and clients are in-mesh:
  - preferred multitenancy direction is to rely on Istio **auto-mTLS** (avoid a global `*.local` `ISTIO_MUTUAL` override) so in-mesh clients can reach out-of-mesh services without per-service exception sprawl,
  - if a global `*.local` client-side mTLS default is present, add a narrow exception (`DestinationRule` with `tls.mode: DISABLE`) for the Postgres Service host,
  - always secure the DB via NetworkPolicies + Postgres auth (and DB-native TLS where/when enabled).
- **Batch jobs talking to out-of-mesh TCP** (e.g. `pg_dump`) may also use `traffic.sidecar.istio.io/excludeOutboundPorts: "5432"` to avoid Envoy mTLS interception for that port while keeping the Job injected for other policy/telemetry.

- **PowerDNS example (Nov 11, 2025)**: Instead of migrating from the single-host StatefulSet, the `data-postgres-powerdns` overlay provisions the CNPG cluster up front (3 replicas on `shared-rwo`) and exposes an `ExternalName` (`powerdns-postgresql`) so the DNS component can switch without transitional Services. The `powerdns-db-init` Sync hook uses `psql` inside `deploykube/bootstrap-tools:1.4` to apply the schema + initial zone declaratively—no dump/restore or manual `pdnsutil` execs required. Future data services should prefer this “declare once, seed via Job” pattern whenever a clean bootstrap is acceptable.

### Troubleshooting Notes (Nov 9, 2025)
1. **ExternalSecrets & Vault data** – CNPG init pods block on the app + superuser secrets. Ensure Vault contains `appPassword` and `superuserPassword` before the Application syncs, and consider adding `mergePolicy: Merge` so ESO overwrites username/password fields atomically.
2. **NetworkPolicies vs. control plane** – blocking TCP/443 to `kubernetes.default.svc` caused endless `dial tcp 10.43.0.1:443: i/o timeout`. Either allow that CIDR explicitly or defer NetworkPolicies until we map the required flows.
3. **CRDs & Argo** – CNPG CRDs exceed the default annotation limit. Vendor the Helm output, strip warnings, enable ServerSideApply, and annotate each CRD with `Replace=true` so Argo can install them.
4. **Operator diagnostics** – expect harmless `PodMonitor CRD not present` messages if Prometheus CRDs aren’t installed yet; document that we need `monitoring.coreos.com` CRDs before enabling PodMonitor.
5. **DB seed job** – `forgejo-db-seed` now orchestrates the sqlite → Postgres migration: it executes `forgejo dump --database postgres` inside the running Deployment to produce a Postgres-friendly SQL dump on the shared PVC, scales the Deployment down, resets the CNPG `public` schema via the superuser secret, imports the dump as the application user, and scales the workload back up before writing a sentinel ConfigMap. Failure at any point prevents `forgejo-db-switch` from proceeding so we never flip to an empty database.
Document any future gotchas here so other services (Keycloak, Vault) inherit the fixes.

Keep this doc updated whenever we tweak the base components so future workloads inherit the latest security defaults (PodSecurity, NetworkPolicies, TLS, etc.).
