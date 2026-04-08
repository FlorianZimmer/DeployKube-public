# Toil: Kubernetes OIDC runtime validation (groups claim mapping)

This toil proves that Kubernetes OIDC authentication is working **end-to-end at runtime**:
- kube-apiserver can reach the OIDC issuer (Keycloak)
- tokens include the expected `groups` claim
- RBAC evaluation works (`kubectl auth can-i`)

Related:
- Component: `platform/gitops/components/shared/access-guardrails/README.md`
- Evidence (prod success): private runtime evidence is intentionally omitted from the public mirror.

---

## Option A (recommended): in-cluster runtime smoke (no workstation plugins)

Run the existing smoke CronJob immediately by creating a one-off Job:

```bash
KUBECONFIG=tmp/kubeconfig-prod \
  kubectl -n access-guardrails-system get cronjob access-guardrails-smoke-oidc-runtime -o wide

job_name="access-guardrails-smoke-oidc-runtime-manual-$(date +%Y%m%d%H%M%S)"
KUBECONFIG=tmp/kubeconfig-prod \
  kubectl -n access-guardrails-system create job \
  --from=cronjob/access-guardrails-smoke-oidc-runtime "${job_name}"

KUBECONFIG=tmp/kubeconfig-prod \
  kubectl -n access-guardrails-system logs -f "job/${job_name}"
```

Success signal:
- output includes the expected `Groups` entry (default: `dk-platform-admins`)
- ends with a success line (the smoke prints `[oidc-runtime] success`)

---

## Option B: workstation OIDC login smoke (human flow)

This path validates the workstation-side OIDC login + kube-apiserver auth using `kubectl oidc-login`.

Prereqs:
- `kubectl` + `kubectl oidc-login` plugin installed (krew).
- Workstation DNS can resolve `keycloak.<env>.internal.example.com`.

Run:

```bash./shared/scripts/smoke-kubernetes-oidc-runtime.sh \
  --from-context admin@kube-proxmox \
  --from-kubeconfig tmp/kubeconfig-prod \
  --deployment-id proxmox-talos \
  --expected-group dk-platform-admins \
  --grant-type device-code \
  2>&1 | tee "tmp/oidc-smoke-$(date +%Y%m%d%H%M%S).log"
```

Notes:
- Prefer `--grant-type device-code` when running from remote shells to avoid localhost callback issues.
- The script forces `--token-cache-storage=none --force-refresh` so it always exercises the login flow.
