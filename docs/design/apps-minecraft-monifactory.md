# Design: Minecraft (Monifactory) Server (GitOps)

Date: 2025-12-20

## Summary

Deploy a single, persistent, modded Java Minecraft survival server running **Monifactory Beta 0.13.0** on the DeployKube cluster, exposed via a Kubernetes `Service` for external connectivity (internet port-forwarding handled outside the cluster). The server is protected with the Minecraft whitelist and administered via in-cluster RCON.

Everything (workloads, config, secrets wiring, and exposure) is declared in `platform/gitops/` and reconciled by Argo CD.

## Tracking

- Canonical tracker: `docs/component-issues/minecraft-monifactory.md`

## Goals

- Run one **dedicated** Minecraft Java server for **Monifactory Beta 0.13.0** with persistent world storage.
- External connectivity via Kubernetes `Service` (TCP `25565`), with the operator handling upstream port-forwarding/NAT.
- Player access controlled via **whitelist** (and `online-mode=true` by default).
- Document JVM flags + RAM sizing and validate/tune using **spark** profiling.
- Ensure clients can use **Distant Horizons** when connecting (client-side); optionally support server-side DH features if desired.

## Non-goals (initial)

- Multi-server hosting, multi-world fleets, or dynamic provisioning.
- Highly-available game server (single replica by design).
- Formal restore drills (we back up automatically, but still need to test and document restores).
- “Zero-downtime” modpack upgrades.

## Constraints / Reality Check

### Modloader compatibility (important)

Monifactory is a **Minecraft 1.20.1 / Forge** modpack (CurseForge distribution). Performance tuning therefore focuses on **Forge-compatible** optimizations; Fabric-first mods like Lithium/C2ME are out of scope.

## Proposed Implementation (GitOps)

### Component layout

- Argo app: `platform/gitops/apps/base/apps-minecraft-monifactory.yaml`
- Component:
  - `platform/gitops/components/apps/minecraft-monifactory/base`
  - `platform/gitops/components/apps/minecraft-monifactory/overlays/<env>`

### Workload

- `Deployment` (single replica, `Recreate`) with a `PersistentVolumeClaim` mounted at `/data`.
- Container image: `itzg/minecraft-server` (or `registry.example.internal/itzg/minecraft-server`), because it:
  - Can install Forge + modpacks at runtime.
  - Supports whitelist/ops/RCON via env vars.
  - Makes GitOps configuration straightforward.

### Modpack acquisition (CurseForge)

Primary option (recommended for automation):

- Use itzg’s `TYPE=AUTO_CURSEFORGE` with `CF_SLUG=monifactory` and pin the desired file via `CF_FILE_ID`.
- Store the required `CF_API_KEY` in Vault and sync it into the namespace with External Secrets Operator.
  - Current pin (in GitOps manifests): `CF_FILE_ID=7328733` (Monifactory Beta 0.13.0 **server** pack; published 2025-12-14).

Fallback option (if AUTO_CURSEFORGE is problematic):

- Use the official “Server” zip from CurseForge as a “generic pack” + custom entrypoint logic, but this typically costs us automation and repeatability. Keep this as a Plan B.
  - Reference: Monifactory Beta 0.13.0 Server zip file id `7328733` (published 2025-12-14).

### Additional mods

- Always add **spark** server-side for profiling and capacity planning (and keep it installed unless there’s a compelling reason not to).
- Treat “performance mods” as a **Forge-compatible** set validated empirically with spark.

#### Verified performance mods already included (Monifactory Beta 0.13.0 server pack)

From the Monifactory Beta 0.13.0 **server pack zip** (as installed by `TYPE=AUTO_CURSEFORGE`):

- Core server-relevant: **FerriteCore**, **ModernFix**, **Radium** (Lithium fork/port), **Noisium**
- Additional “helps servers too” or mixed: **AI Improvements**, **Clumps**, **FastFurnace**, **SmoothChunk**, **Connectivity**
- Client-focused (present in server pack, but not a server priority): **ImmediatelyFast**, **EntityCulling**, **BetterFpsDist**, **SmoothBoot (Reloaded)**

#### Still advised (start small)

- **spark** (profiling; not included in the server pack zip)
- **Chunk pregeneration** (e.g. a pregenerator mod) if exploration/chunkgen MSPT spikes become noticeable; do this after we confirm modpack stability on a dedicated server.

### Client: Distant Horizons

- **Clients can use Distant Horizons without any server changes** (client-side rendering + LOD generation).
- In general, a server-side DH mod is **not required** and often provides limited benefit compared to its stability/compat risk in large Forge modpacks. Re-evaluate only if you specifically want server-provided LOD data workflows and the modpack maintainers recommend it.

## Resource Sizing & JVM Configuration

### Baseline sizing (starting point)

Start conservative and tune based on real usage:

- **RAM**: `8Gi` allocated to the JVM heap (initial), with headroom on the node for native memory and file caches.
- **CPU**: request `2` cores, allow bursts higher if the cluster can.
- Single replica and `Recreate`-style semantics (StatefulSet already serializes mounts).

### Heap settings

For modded servers, stability is usually best when:

- `Xms == Xmx` (avoid heap resizing overhead).
- The container memory limit is comfortably above the heap to account for:
  - Metaspace + JIT + thread stacks
  - Direct buffers (Netty)
  - Native allocations from some mods

Example target:

- Heap `-Xms8G -Xmx8G`
- Container limit `~10–12Gi` (exact number depends on node capacity)

### JVM flags (G1GC baseline)

Default to G1GC (safe for Java 17). Use one of:

1) itzg built-in `USE_AIKAR_FLAGS=true` (simple and battle-tested), or
2) Explicit `JVM_XX_OPTS` + `JVM_OPTS` (more control).

If we need to push very large heaps (16G+) and are on Java 21 with good compatibility, evaluate ZGC later; don’t start there.

### Validation with spark (required)

Use spark to validate these decisions:

- Confirm **MSPT** under load (e.g., chunk gen, exploring, farms).
- Identify hotspots (mods, worldgen, entity ticking).
- Compare configs:
  - view-distance / simulation-distance
  - pregen vs. on-demand chunk generation
  - CPU throttling vs. no throttling

Evidence discipline: capture the exact spark command and a summary of the results in the component README (and/or `docs/component-issues/minecraft-monifactory.md`).

## Recommended Server Parameters (Small Group, Strong Hardware)

Defaults implemented in GitOps (adjust after spark + real play):

- `view-distance=12`, `simulation-distance=10` (good experience for exploration without immediately exploding tick time)
- `max-players=10`
- `spawn-protection=0`
- `max-tick-time=-1` (disable vanilla watchdog; modded chunkgen spikes can otherwise crash the server)

Notes:

- Monifactory explicitly supports playing on Peaceful; if you want the intended “no-mob grind” experience, set `difficulty=peaceful`.
- If exploring causes MSPT spikes, prefer **chunk pregeneration** and/or lower view distance before increasing heap.

## Networking / Exposure

- Expose TCP `25565` via a `Service` of type `LoadBalancer` (MetalLB on Proxmox/Talos).
- Keep RCON internal-only:
  - `Service` type `ClusterIP` on `25575`
  - Or no service and use `kubectl port-forward` for admin.

Operator handles internet port-forwarding to the chosen `LoadBalancer` IP.

## Persistence, Backups, and Restore

### Persistence

- `PersistentVolumeClaim` (RWO) for `/data`:
  - world saves
  - configs
  - mods/cache downloaded by the server

### Backups (design)

Implemented (GitOps):

- In-pod backup sidecar using **`itzg/mc-backup`** with **restic** to Garage (S3).
- Backup interval: **every 10 minutes** (use `INITIAL_DELAY` per-server to stagger when adding multiple servers).
- Storage layout: backups go into the Garage bucket `BUCKET_BACKUPS` (default `garage-backups`) using a per-server prefix (`/minecraft-monifactory`).
- Retention (restic forget/prune):
  - keep **all snapshots within 2h**
  - keep **hourly** snapshots for **24h**
  - keep **daily** snapshots for **7d**
  - keep **weekly** snapshots for **52w**

Restore runbook (initial):
1) Scale the Deployment to 0.
2) Run `restic restore` into an empty `/data` (or restore only `world/`).
3) Scale back to 1 and verify world + modpack boot.

## Security & Administration

- `online-mode=true` by default.
- `white-list=true` and `enforce-whitelist=true`.
- Admin:
  - `ops.json` via env (`OPS`) or declarative file strategy
  - RCON enabled; password stored in Vault
- Consider limiting exposure at the network layer (router/firewall), even with whitelist enabled.

### Whitelist management (reconciled)

- Source of truth: Vault `secret/apps/minecraft-monifactory/access` (`whitelist`, `ops` text blobs).
- ESO projects that into `Secret/minecraft-monifactory-access`.
- A sidecar reconciles the whitelist via RCON (`whitelist add/remove`) and ensures `op` for listed admins (best-effort).

## Dev → Prod

- Dev overlay pins a MetalLB IP (Proxmox/Talos) and uses the default storage class.
- Prod overlay should explicitly define:
  - MetalLB IP / exposure strategy
  - Storage class and capacity
  - Backup destination + retention + restore procedure
  - Update process (maintenance window expectations)

Implementation status and open follow-ups live in `docs/component-issues/minecraft-monifactory.md`.
