# Tenant-facing S3 primitive (Garage) — ordering + troubleshooting

This toil documents the v1 flow for tenant-facing S3 buckets backed by Garage:

- **Git intent** (bucket list) under `platform/gitops/tenants/<orgId>/...`
- **Platform-owned provisioner** creates bucket + key and writes to Vault
- **Platform-owned projection** via ESO into tenant namespaces (tenants consume a `Secret`, not ESO CRDs)
- **Network guardrails**: S3 allowlisted per tenant identity; Garage admin/RPC never reachable from tenant namespaces

Design: `docs/design/multitenancy-storage.md` (tenant-facing S3 + reachability guardrails)

---

## Contracts

### Vault secret path + keys

Tenant bucket credentials live under:
- Vault logical key: `tenants/<orgId>/s3/<bucketName>`
- KV v2 API paths:
  - `secret/data/tenants/<orgId>/s3/<bucketName>`
  - `secret/metadata/tenants/<orgId>/s3/<bucketName>`

Values:
- `S3_ENDPOINT`, `S3_REGION`
- `S3_BUCKET` (the actual Garage bucket alias; v1 uses `tenant-<orgId>-<bucketName>` with a hash fallback for long names)
- `S3_ACCESS_KEY`, `S3_SECRET_KEY`

### Tenant Kubernetes Secret contract

The platform projects tenant bucket credentials into a tenant namespace Secret (example name for `bucketName=app`):
- `Secret/<tenantNamespace>/tenant-s3-app`

Keys (current convention):
- `S3_ENDPOINT`, `S3_REGION`, `BUCKET`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`

---

## Ordering a bucket (GitOps flow)

For a tenant bucket `<bucketName>` (example: `app`):

1) Add a tenant S3 intent `ConfigMap` in the `garage` namespace (Git-managed, but not tenant-authored at runtime):
   - Example: `platform/gitops/tenants/smoke/projects/demo/namespaces/prod/configmap-garage-tenant-s3-intent-app.yaml`

2) Ensure the tenant namespace has an egress allow `NetworkPolicy` to Garage S3 (`:3900`):
   - Example: `platform/gitops/tenants/smoke/projects/demo/namespaces/prod/networkpolicy-allow-garage-s3-egress.yaml`

3) Add a platform-owned `ExternalSecret` in the tenant namespace that projects `tenants/<orgId>/s3/<bucketName>`:
   - Example: `platform/gitops/tenants/smoke/projects/demo/namespaces/prod/externalsecret-tenant-s3-app.yaml`

4) Allowlist the tenant identity on the Garage ingress side (do not allow all tenants):
   - `platform/gitops/components/storage/garage/base/networkpolicy.yaml` (`NetworkPolicy/garage-ingress`)
   - Add a `namespaceSelector.matchLabels` stanza keyed by:
     - `darksite.cloud/rbac-profile=tenant`
     - `darksite.cloud/tenant-id=<orgId>`
     - `darksite.cloud/project-id=<projectId>` (optional extra fence; recommended in Tier S)

5) Commit + seed Forgejo, then let Argo reconcile.

---

## Force provisioning now (don’t wait for the hourly CronJob)

```bash
KUBECONFIG=tmp/kubeconfig-prod \
  kubectl -n garage create job --from=cronjob/garage-tenant-s3-provisioner \
  garage-tenant-s3-provisioner-manual-$(date +%Y%m%d%H%M%S)
```

Follow logs:

```bash
job=garage-tenant-s3-provisioner-manual-<timestamp>
KUBECONFIG=tmp/kubeconfig-prod kubectl -n garage logs "job/${job}" --all-containers
```

---

## Verify (positive + negative)

### Positive: tenant can read/write its own bucket

Create a short-lived test Job in the tenant namespace (uses `rclone` from `bootstrap-tools`):

```bash
ns=t-<orgId>-p-<projectId>-prod-app
KUBECONFIG=tmp/kubeconfig-prod kubectl -n "${ns}" apply -f - <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  name: tenant-s3-smoke
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      containers:
        - name: test
          image: registry.example.internal/deploykube/bootstrap-tools:1.4
          imagePullPolicy: IfNotPresent
          envFrom:
            - secretRef:
                name: tenant-s3-app
          command: ["/bin/bash","-lc"]
          args:
            - |
              set -euo pipefail
              cat > /tmp/rclone.conf <<EOF
              [garage]
              type = s3
              provider = Other
              env_auth = false
              access_key_id = ${S3_ACCESS_KEY}
              secret_access_key = ${S3_SECRET_KEY}
              endpoint = ${S3_ENDPOINT}
              region = ${S3_REGION}
              force_path_style = true
              EOF
              obj="smoke-$(date -u +%Y%m%d%H%M%S).txt"
              printf 'hello %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/tmp/payload.txt
              rclone --config /tmp/rclone.conf copyto /tmp/payload.txt "garage:${BUCKET}/${obj}"
              rclone --config /tmp/rclone.conf cat "garage:${BUCKET}/${obj}"
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
YAML
```

### Negative: tenant cannot reach Garage admin/RPC

From a tenant pod/job, verify `garage.garage.svc` ports `3903` and `3901` are unreachable (blocked by Garage ingress `NetworkPolicy`).

### Negative: tenant cannot access other tenants’ buckets

Attempt to list a different bucket with the same credentials; expect `AccessDenied` / HTTP 403.

### Negative: non-allowlisted tenant namespace cannot reach S3

If a tenant namespace is **not** present in the Garage ingress allowlist, S3 connections to `garage.garage.svc:3900` should fail even if the tenant has an egress allow `NetworkPolicy`.

---

## Troubleshooting

### ExternalSecret is not Ready / Secret missing

1) Check the tenant secret exists:

```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl -n <tenantNamespace> get secret tenant-s3-app -o name
```

2) Inspect ExternalSecret events:

```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl -n <tenantNamespace> describe externalsecret tenant-s3-app
```

Common causes:
- Vault key does not exist yet → run the provisioner job manually.
- Incorrect `remoteRef.key` / `property` mappings.
- ESO cannot reach Vault (check `vault-system` NetworkPolicy allowlist for provisioners and ESO).

### Provisioner runs but bucket/secret doesn’t appear

Inspect the provisioner job logs:

```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl -n garage logs cronjob/garage-tenant-s3-provisioner --tail=200
```

And the most recent job:

```bash
KUBECONFIG=tmp/kubeconfig-prod kubectl -n garage get jobs -l app.kubernetes.io/component=tenant-s3-provisioner
```

Verify required prerequisites exist:
- `Secret/garage/garage-credentials` contains `GARAGE_ADMIN_TOKEN`
- Vault role exists: `k8s-garage-tenant-s3-provisioner` (reconciled by `CronJob/vault-tenant-s3-provisioner-role`)
- Garage ingress allowlist includes the target tenant namespace labels

---

## Rotation / revocation (v1)

Provisioner behavior:
- If `secret/tenants/<orgId>/s3/<bucketName>` exists, the provisioner reuses the stored key material.
- If it does not exist, it generates a new key pair, writes Vault, provisions/ACLs the bucket.

To rotate credentials for a bucket:
1) Delete the Vault secret `secret/tenants/<orgId>/s3/<bucketName>`.
2) Re-run the provisioner job.
3) Allow ESO to refresh the tenant Secret (or force-sync ESO if needed).
4) Roll tenant workloads that consume the Secret.

Offboarding (bucket deletion + Vault subtree wipe) is tracked as a lifecycle milestone; do not “rm -rf” data without evidence.

Operator toils (v1):
- `docs/toils/tenant-offboarding.md`
