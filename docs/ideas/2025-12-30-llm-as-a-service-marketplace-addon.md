# Idea: LLM as a Service (LLMaaS) Marketplace Addon

Date: 2025-12-30
Status: Draft
Owner: Florian

## Problem statement

DeployKube should offer an optional, sellable **LLM as a Service (LLMaaS)** addon that runs *inside* the customer’s private cloud and integrates with the platform’s existing contracts (GitOps, IAM, secrets, TLS, observability).

The addon should provide:
- An intuitive **end-user UI** (chat + workspaces) and a stable **API** surface for apps.
- Easy onboarding of **documentation sources** for RAG (e.g., Git repos, S3 buckets, uploaded files, and later additional connectors).
- Optional use of:
  - **local models** (offline / sovereign), and
  - **remote providers** (e.g., ChatGPT/OpenAI) when customers explicitly allow data egress.
- “Work output” features: generate **images**, **diagrams/graphs**, **documents**, and **presentations** (as stored artefacts with shareable links).
- Prefer existing OSS building blocks, but only with licenses compatible with commercial resale (and with a clear separation between *software license* vs *model weights license*).

This addon must integrate with the Marketplace model described in `docs/ideas/2025-12-26-marketplace-managed-services.md` (Fully Managed Services vs Curated Deployments) and should be implementable in a GitOps-first way.

## Why now / drivers

- Sovereign/private-cloud customers increasingly want “AI inside the perimeter” for policy and data-control reasons.
- An LLM service is a high-leverage platform addon: it can power both operator workflows (troubleshooting, docs, runbooks) and tenant workflows (developer/self-service).
- DeployKube already has most of the integration primitives required to make this coherent (Keycloak, Vault/ESO, Step CA/cert-manager, Garage S3, CNPG Postgres, LGTM observability, Istio).

## Proposed approach (high-level)

### 1) Marketplace positioning: two product classes

Align with the Marketplace split:

1) **Fully Managed Service (FMS): “Managed LLM Workspace”**
- Provider operates the service (upgrades, backups, monitoring, incident response, capacity).
- Tenants consume it as:
  - a UI (`https://llm.<env>...`) and/or
  - a stable API (ideally OpenAI-compatible) for programmatic use.
- Recommended default for most customers, because model serving, vector indexing, and GPU sizing are operationally non-trivial.

2) **Curated Deployment: “Self-hosted LLM stack”**
- A hardened GitOps package that tenants operate themselves (still integrated with IAM/TLS/secrets/observability).
- Useful for customers who want full control, custom models, or special compliance constraints.

The same architecture can support both, but the responsibilities matrix must be explicit (especially around data retention, egress, model licensing, and abuse controls).

### 2) Service shape: “Workspaces” as the unit of tenancy

Model the LLMaaS addon around **Workspaces**:
- A workspace is the unit of:
  - data ownership (documents, chats, artefacts),
  - configuration (allowed model providers, tool permissions),
  - quotas/budgets (token limits, concurrency),
  - retention (how long to keep chat logs and uploaded docs).

Workspaces map cleanly to future Marketplace APIs:
- `ServiceCatalogItem`: `llm-workspace`
- `ServicePlan`: `cpu-small`, `gpu-small`, `gpu-medium`, `remote-only`, `hybrid`
- `ServiceInstance`: one ordered workspace (tenant-scoped)
- (Optional) `ServiceBinding`: how an app gets an API token + endpoint for that workspace

### 3) Reference architecture (data plane)

At a high level, each workspace needs:

- **UI**: chat + workspace management + documents + artefacts gallery.
- **Orchestrator API**: routes requests to providers, enforces quotas, records audit/usage, manages tools.
- **RAG index**:
  - raw documents stored in object storage (Garage S3),
  - metadata in Postgres,
  - vector index in either Postgres (`pgvector`) or a dedicated vector DB.
- **Model providers** (pluggable):
  - local inference (CPU/GPU),
  - remote providers (OpenAI/ChatGPT etc.),
  - “bring-your-own endpoint” (OpenAI-compatible URL).
- **Tool workers** for artefact generation:
  - docs/presentations rendering,
  - diagram/chart rendering,
  - image generation (local diffusion or remote provider).

Implementation stance:
- Keep “control” components (UI/orchestrator/indexer) stateless and horizontally scalable.
- Put state in Postgres + S3 + (optional) vector DB.
- Treat GPU inference as a separate, isolatable runtime tier (and optionally shared across workspaces).

### 4) Provider abstraction: local + remote without changing the UI

Introduce a “provider router” concept in the orchestrator:
- **Chat provider**: local model server or remote LLM API.
- **Embedding provider**: local embedding model server or remote embeddings API.
- **Image provider**: local diffusion runtime or remote image API.

Key idea: the UI and apps should mostly talk to one stable API, while the backend decides where to run.

For interoperability and ecosystem tooling, prefer supporting an **OpenAI-compatible API** for:
- chat/completions,
- embeddings,
- images (where feasible),
plus a small set of service-specific endpoints (workspace management, document sources, artefacts).

### 5) Document sources: connectors as isolated sync/index pipelines

To “easily add new sources of docs”, treat each source as a connector type:
- Git (clone/pull)
- S3 bucket/prefix
- File uploads (UI)
- Later: web crawler, Confluence, Google Drive, etc.

Design principle:
- Connectors run as **isolated Jobs/CronJobs** with least privilege (and narrow egress when needed).
- Output is normalized into:
  - raw blobs (S3),
  - extracted text + metadata (Postgres),
  - embeddings/vectors (vector store).

This makes “add a new connector” mostly a matter of adding a new worker image + a small API surface, without coupling everything into the UI.

### 6) “Work outputs”: artefact generation as a first-class product feature

Treat generated artefacts as stored, shareable objects:
- Markdown/HTML/PDF documents
- PPTX presentations (or HTML slide decks)
- Images
- Diagrams (Mermaid/SVG/PNG)
- Charts/graphs (PNG/SVG from a sandboxed plotting runtime)

Operationally, this is a good fit for:
- a queue + worker pattern (K8s Jobs or a small worker Deployment),
- artefacts stored in S3 with pre-signed URLs,
- metadata in Postgres for search and retention policies.

### 7) Multi-tenancy, security, and data egress posture

This addon must be explicit about data boundaries:
- **IAM**: Keycloak OIDC for UI + API; workspace roles mapped from Keycloak groups.
- **Secrets**: provider keys and connector credentials stored in Vault (via ESO), never in plaintext manifests.
- **TLS**: Step CA + cert-manager for all ingresses; internal mTLS via Istio.
- **Egress controls**:
  - local/offline mode: no internet egress required,
  - remote-provider mode: explicit, allow-listed egress only to configured providers.
- **Auditability**:
  - who accessed which workspace,
  - which provider was used,
  - what documents were indexed,
  - artefact creation events.

Security warning: if “tools” include code execution (e.g., python for charts), it must run in a heavily sandboxed environment (non-root, no host mounts, strict network policy, resource limits).

### 8) OSS reuse + licensing doctrine (sellable)

Two separate axes must be managed:
1) **Software licenses** (code you ship/run).
2) **Model weights and dataset licenses** (what you bundle vs what the customer supplies).

Practical stance:
- Prefer permissive software licenses (Apache-2.0/MIT/BSD) and avoid strong copyleft in the core path.
- Avoid bundling model weights by default; instead:
  - support BYOM (customer-provided models),
  - optionally ship a “known-good starter model list” with explicit license checks and a documented download/mirroring workflow.

Candidate OSS building blocks (license compatibility must be re-verified at implementation time):
- UI: Open WebUI (BSD-3-Clause) or a small custom UI
- Local inference: vLLM (Apache-2.0) and/or Hugging Face TGI (Apache-2.0); CPU-only fallback via llama.cpp
- RAG frameworks (optional): Haystack (Apache-2.0), LangChain (MIT), LlamaIndex (MIT)
- Vector store: Postgres + pgvector, or Qdrant (Apache-2.0)
- Diagrams/slides/docs: Mermaid (MIT), Marp (MIT), WeasyPrint (BSD), python-pptx (MIT), python-docx (MIT), diffusers (Apache-2.0)

## What is already implemented (repo reality)

DeployKube already provides many prerequisites the addon should build on:
- GitOps delivery via Forgejo + Argo CD (`docs/design/gitops-operating-model.md`).
- Platform IAM via Keycloak (`target-stack.md`).
- Secrets via Vault + ESO (`target-stack.md`).
- TLS via Step CA + cert-manager (`target-stack.md`).
- Storage primitives:
  - S3-compatible object storage (Garage) for documents/artefacts.
  - CNPG Postgres for metadata and (optionally) vectors.
- Observability via the LGTM stack (`target-stack.md`).
- Istio mesh with STRICT mTLS as the default posture (`target-stack.md`).

Additionally, there is an existing non-Kubernetes codebase that can be leveraged:
- `llama-suite` (local tooling + WebUI) (separate repo in the author’s workspace).

## What is missing / required to make this real

### 1) Marketplace API and reconciliation layer

The Marketplace CRDs/controller described in `docs/ideas/2025-12-26-marketplace-managed-services.md` are not implemented yet.

LLMaaS can still start as a platform component (single shared instance), but to truly integrate with the Marketplace we need:
- a catalog/plan/instance API,
- a controller that provisions a workspace instance and emits status/usage.

### 2) GPU and local model serving substrate

DeployKube currently has no in-repo “GPU baseline” (node pools, drivers, scheduling constraints, quotas).

For local inference beyond small CPU models, we need:
- a GPU enablement story (node images/drivers/operator),
- a model-serving runtime tier (vLLM/TGI/llama.cpp) with resource governance.

For a more specific candidate architecture around **llm-d + Gateway API Inference Extension + optional Higress edge fronting**, see `docs/ideas/2026-03-26-llm-d-higress-inference-gateway-layering.md`.

### 3) Data model + retention policy

Define and enforce:
- chat retention and privacy policy (per workspace/plan),
- document retention and re-indexing behavior,
- artefact retention and link sharing model.

### 4) Connector framework and least-privilege policy

We need a standard for:
- connector definitions (CRDs or internal API objects),
- credential flow via Vault,
- network egress restrictions per connector/provider,
- safe parsing (file-type handling, size limits, AV scanning if required).

### 5) Abuse controls and quota enforcement

To be sellable, the service must provide predictable consumption controls:
- per-workspace token budgets and rate limits,
- per-tool permissions (image generation, code execution),
- clear “who pays” model for shared provider keys vs BYOK.

## Can we make `llama-suite` cloud-ready? (high-level)

Yes, but it should be treated as a **starting point**, not the final architecture.

What maps well already:
- FastAPI server + SPA static hosting is deployable as a standard Kubernetes Deployment.
- The code already has a notion of “project root” and structured dirs (`configs/`, `runs/`, `var/`).

Key gaps to close for Kubernetes readiness:
- **State**: replace local “project root” state with explicit mounts (PVCs) and/or S3/DB backends.
- **Process model**: replace “spawn local llama.cpp processes” and “manage Docker containers” with:
  - separate Kubernetes Deployments for model servers, and/or
  - Jobs/CronJobs for eval/bench workloads.
- **Auth**: integrate Keycloak OIDC (and map workspaces/roles); remove implicit “localhost operator UI” assumptions.
- **Multi-tenancy**: separate per-tenant/per-workspace data and enforce quotas.
- **Ops**: add health probes, structured logging/metrics, and a GitOps packaging (Helm/Kustomize) story.

Likely best use of `llama-suite` in the LLMaaS product:
- “Operator/admin surface” for model benchmarking/evaluation and curated model catalog management,
- plus reusable UI components/patterns where they fit.

## Risks / weaknesses

- **Model license complexity**: “commercially sellable” depends heavily on model weight licenses; bundling models is risky without a compliance process.
- **GPU operational burden**: GPU scheduling, upgrades, and capacity planning can dominate operational complexity.
- **Data egress ambiguity**: remote-provider mode must be explicit and provable (policy + UI cues), or it can violate customer expectations.
- **Security blast radius from tools**: code execution and document parsing are common escalation points; sandboxing and strict policies are mandatory.
- **UI scope creep**: “make docs, presentations, images, graphs” can turn into a full productivity suite; MVP boundaries must be tight.

## Alternatives considered

- “Just deploy Open WebUI”: great chat UX, but doesn’t solve multi-tenant workspace lifecycle, document sources, quotas, artefact generation, or marketplace integration.
- “Only remote providers”: simplest operationally, but undermines the sovereign/offline value proposition.
- “Bundle a full local model pack”: improves day-1 experience, but significantly increases licensing and distribution risk.

## Open questions

- Is LLMaaS primarily a **tenant-facing service**, an **operator productivity layer**, or both?
- Where should local model weights live:
  - per-workspace (strong isolation, expensive),
  - shared GPU pool (efficient, needs strong governance),
  - per-tenant pool?
- Do we want the API to be fully OpenAI-compatible, or “mostly compatible + extensions”?
- How do we encode “no egress” as an enforceable contract (namespace policy, egress gateway, deny-by-default)?
- Which artefact formats are MVP vs later (PDF vs PPTX vs both)?

## Promotion criteria (to `docs/design/**`)

Promote this idea once we have:
- A concrete marketplace interface for this addon:
  - initial CRDs/objects for ordering a workspace + a plan, and
  - a reconciliation/controller approach (managed vs curated is explicit).
- A minimal reference architecture decision:
  - Postgres+S3 as the state core, and
  - a chosen inference runtime baseline (CPU-only MVP vs GPU-enabled).
- A licensing doctrine for:
  - OSS components, and
  - model weights (BYOM vs bundled), including a compliance checklist.
- One end-to-end MVP defined (even if not implemented yet) with explicit boundaries:
  - UI + API,
  - one connector type,
  - one artefact type,
  - one provider (local or remote),
  - quota enforcement and audit logging expectations.
