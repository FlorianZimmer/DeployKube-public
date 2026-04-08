# Idea: llm-d + Higress Inference Gateway Layering

Date: 2026-03-26
Status: Draft
Owner: Florian

## Problem statement

DeployKube's broader LLMaaS direction needs a concrete view of the **local inference serving path**. The main architectural question is where to place an AI/API gateway such as Higress relative to an inference-aware serving stack such as llm-d, and which layer should own request placement decisions.

The risk is collapsing two different concerns into one vague "AI gateway" bucket:
- **north-south API gateway concerns**: auth, quotas, protocol adaptation, caching, policy, observability
- **inference-serving concerns**: prompt-aware endpoint selection, prefix-cache-aware routing, latency/load-aware scheduling, prefill/decode-aware placement

If those responsibilities are not separated cleanly, we will either:
- lose llm-d's inference-aware scheduling value, or
- overcomplicate the edge path with an unsupported gateway combination.

## Why now / drivers

- The existing LLMaaS idea doc needs a more concrete candidate for the "local model serving substrate" decision.
- DeployKube already ships **Gateway API CRDs** and an **Istio Gateway API ingress path**, so this idea can build on existing platform primitives instead of inventing a completely separate traffic contract.
- An eventual marketplace or managed LLM addon will likely need both:
  - an enterprise-grade edge/API layer, and
  - an inference-aware backend routing layer.
- The upstream llm-d model is opinionated enough that it is worth capturing now before implementation work starts.

## Proposed approach (high-level)

### 1) Treat this as a two-layer architecture

**Layer 1: AI/API edge**
- Optional Higress in front of the serving path
- Owns edge-facing concerns:
  - authentication/authorization
  - rate limits and quotas
  - token accounting
  - API normalization / OpenAI-compatible proxy behavior
  - semantic cache and policy/security plugins

**Layer 2: inference-aware backend routing**
- Gateway API + Gateway API Inference Extension
- `InferencePool`
- llm-d Endpoint Picker / inference scheduler
- llm-d model-serving backends (for example vLLM- or SGLang-based pods)

This keeps the boundary explicit: Higress is gateway intelligence; llm-d is inference placement intelligence.

### 2) Default recommendation for DeployKube

Use **llm-d + InferencePool + a documented/supported Gateway API provider** as the core serving path.

Add **Higress in front** only when DeployKube needs stronger API-gateway features that llm-d is not trying to solve itself, such as:
- multi-provider API proxying
- richer auth/policy enforcement
- semantic caching
- token governance
- gateway-level observability and security plugins

Do **not** treat Higress as a replacement for llm-d's scheduler or `InferencePool` abstraction unless the full Gateway API Inference Extension contract is proven end to end.

### 3) Reference request flow

1. Client sends an OpenAI-style request to Higress.
2. Higress applies edge policy such as auth, rate limiting, protocol adaptation, cache, or request governance.
3. Higress forwards to a Gateway API Inference Extension route targeting an `InferencePool`.
4. The gateway consults the llm-d Endpoint Picker / inference scheduler.
5. llm-d selects the best backend based on live inference state and scheduler policy.
6. The selected model-serving pod handles the request.

### 4) Gateway-provider stance

The safest current reading is:
- llm-d is centered on **Gateway API + Inference Extension**
- the gateway implementation can vary
- llm-d's documented happy path currently emphasizes **agentgateway / Istio / GKE** compatibility paths
- Higress is conceptually compatible only if it fully participates in the same inference-extension contract

That means Higress should be viewed as:
- a potentially valid **fronting edge gateway**, or
- a possible gateway implementation candidate to evaluate later,

but **not yet** as DeployKube's default llm-d installation target.

## What is already implemented (repo reality)

DeployKube already has several prerequisites that make this direction plausible:

- **Gateway API CRDs** are already shipped as a dedicated early-sync GitOps component:
  - `platform/gitops/components/networking/gateway-api/`
  - `target-stack.md`
- **Gateway API ingress via Istio** already exists:
  - `platform/gitops/components/networking/istio/gateway/`
  - `target-stack.md`
- The platform already has the surrounding control-plane primitives an LLM addon would need:
  - GitOps delivery via Argo/Forgejo
  - Keycloak IAM
  - Vault/ESO secret delivery
  - cert-manager / Step CA TLS
  - LGTM observability

What is **not** in-repo today:
- no llm-d packaging
- no Higress packaging
- no Gateway API Inference Extension CRDs/components
- no `InferencePool`-based routing path
- no GPU baseline or node lifecycle for model serving
- no vLLM/SGLang/TGI baseline

## What is missing / required to make this real

### 1) A concrete serving baseline decision

Choose one explicit baseline such as:
- **llm-d + supported gateway provider + vLLM**
- **llm-d + supported gateway provider + SGLang**

This should be treated as the reference architecture before considering optional Higress fronting.

### 2) Gateway API Inference Extension packaging

We would need a GitOps-native installation story for:
- Gateway API Inference Extension CRDs/controllers
- any required llm-d scheduler/EPP components
- ordering guarantees so CRDs land before CRs

### 3) Model-serving runtime package(s)

We would need at least one product-owned or curated runtime package for backend serving:
- vLLM
- SGLang
- or another clearly justified runtime

This package needs:
- image/version pinning
- readiness/smoke checks
- observability hooks
- rollback guidance

### 4) Gateway choice and contract proof

Before treating Higress as part of the core path, we need proof that one of these is true:
- Higress cleanly supports the same Gateway API Inference Extension flow end to end, or
- DeployKube keeps Higress strictly as an edge gateway in front of a separate llm-d-supported gateway path

### 5) GPU and tenancy posture

Local inference becomes real operationally only if DeployKube also defines:
- GPU enablement and scheduling policy
- workspace/tenant quota model
- model weight custody / mirroring / licensing posture
- egress policy for hybrid local+remote provider modes

## Risks / weaknesses

- **Unsupported gateway combinations**: "supports Gateway API" is weaker than "works as a first-class llm-d provider path."
- **Double-gateway complexity**: putting Higress in front of another gateway layer may add latency, failure domains, and debugging complexity.
- **Feature overlap**: caching, retries, model routing, and token governance can become ambiguous if split across both layers without a clear contract.
- **Upstream churn**: llm-d's preferred gateway story is still evolving; choosing too early could cause rework.
- **GPU operational cost**: the serving substrate decision is inseparable from node, driver, and capacity strategy.

## Alternatives considered

- **Higress-only AI gateway path**: simpler north-south entrypoint, but weaker fit if inference-aware endpoint picking is the main local-serving requirement.
- **llm-d-only path without Higress**: simplest way to preserve inference-aware routing, but leaves advanced API-gateway features to other components or later work.
- **Direct model server exposure (for example plain vLLM)**: operationally simpler at first, but does not provide the same standard inference-routing abstraction.

## Open questions

- Which gateway implementation should be DeployKube's **first-class** llm-d path: agentgateway, Istio, GKE, or something else?
- Does DeployKube want Higress primarily for:
  - edge auth/policy,
  - multi-provider AI proxying,
  - semantic caching,
  - or all of the above?
- Should the initial product shape be:
  - shared platform inference pool,
  - per-tenant inference pool,
  - or a hybrid model?
- Which runtime should be the first backend baseline: vLLM or SGLang?
- How much OpenAI API compatibility should be guaranteed by the edge layer versus the serving layer?

## Promotion criteria (to `docs/design/**`)

Promote this idea once we have:
- a declared reference architecture:
  - core llm-d path
  - chosen gateway provider
  - chosen backend runtime
- a GitOps packaging plan for:
  - Gateway API Inference Extension
  - llm-d scheduler/EPP
  - backend model-serving runtime
- an end-to-end contract proof for the request path, including:
  - auth edge
  - route object model
  - scheduler interaction
  - backend selection
- an operational stance for:
  - GPU enablement
  - quotas
  - observability
  - rollback
  - evidence collection

Expected repo changes at promotion time:
- one or more new `platform/gitops/components/**` packages for the chosen gateway/runtime path
- component README/runbook material
- component issue tracker(s)
- evidence from at least one working end-to-end inference request path

## Upstream reading captured with this idea

These links are the upstream references that motivated this note and should be re-checked at implementation time:

- `https://llm-d.ai/docs/architecture/Components/inference-scheduler`
- `https://gateway-api-inference-extension.sigs.k8s.io/api-types/inferencepool/`
- `https://llm-d.ai/docs/architecture/Components/infra`
- `https://www.alibabacloud.com/blog/higress-has-supported-the-new-gateway-api-and-its-ai-inference-extension_602891`
- `https://higress.ai/en/docs/latest/plugins/ai/api-provider/ai-proxy/`
- `https://higress.ai/en/`
