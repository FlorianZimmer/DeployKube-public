# DeploymentConfig controller (snapshot publisher + backup-system wiring)

Publishes a canonical in-cluster snapshot of the cluster’s singleton `platform.darksite.cloud/v1alpha1 DeploymentConfig`:

- Output: `ConfigMap/<ns>/deploykube-deployment-config`
- Key: `deployment-config.yaml`

This snapshot is a compatibility layer for Job/CronJob consumers that should not talk to the Kubernetes API directly.

The same controller profile also applies DeploymentConfig-derived backup-plane wiring:

- backup-system Cron schedule fields from `spec.backup.schedules.*`
- static backup PV NFS mount fields (`nfs.server`, `nfs.path`, `mountOptions`) from `spec.backup.target.nfs.*`

## Ownership + field managers

The controller is the authoritative owner of `ConfigMap/*/deploykube-deployment-config`. It applies the snapshot via server-side apply with forced ownership to avoid bootstrap-time `kubectl apply` field-manager conflicts.

## Namespaces

The snapshot is published to:

- `argocd` (platform plumbing + ingress wiring)
- `backup-system` (backup jobs)
- `forgejo` (Forgejo jobs that need the deployment hostnames)
- `grafana` (Grafana smoke tests)
- `keycloak` (bootstrap + IAM sync jobs)
